/* Titanium — per-pass GPU stage profiling.
 *
 * Metal can write GPU timestamps at the boundaries of a render pass's vertex
 * and fragment stages (MTLCounterSamplingPointAtStageBoundary, supported on
 * Apple silicon). On a tile-based GPU those are distinct phases: the vertex
 * stage runs vertex shading, clipping and binning into tiles; the fragment
 * stage shades the tiles. That split is exactly what decides whether a
 * geometry-side change (mesh shaders, GPU culling) can pay off, so this is a
 * measurement tool, not an optimisation.
 *
 * Each sampled pass takes 4 slots in a per-command-buffer sample buffer.
 * Buffers come from a small pool (bounded by frames in flight) and are
 * resolved in the command buffer's completion handler.
 */
#include "ti_internal.h"
#include <time.h>
#include <cmath>
#include <cstring>

static constexpr NSUInteger TI_PROF_SAMPLES = 1024;   /* 256 passes per command buffer */

struct TiPassAgg {
    uint64_t passes = 0, invalid = 0, vertex_ticks = 0, fragment_ticks = 0;
};

struct TiProfiler {
    std::mutex                                  mtx;
    id<MTLCounterSet>                           timestamps;
    std::vector<id<MTLCounterSampleBuffer>>     pool;
    std::unordered_map<std::string, TiPassAgg>  agg;
    std::vector<std::string>                    order;      /* first-seen */
    uint64_t                                    cmdbufs = 0;
    std::atomic<uint64_t>                       unsampled{0};
    /* Bumped by reset: buffers encoded before a reset are discarded when
     * they complete, so an interval counts exactly the frames encoded in it. */
    std::atomic<uint64_t>                       epoch{0};
    /* Calibration: GPU timestamp ticks against a nanosecond clock. */
    MTLTimestamp                                gpu0 = 0;
    uint64_t                                    ns0 = 0;
    bool                                        buffer_failed = false;
};

struct TiProfPending {
    id<MTLCounterSampleBuffer> buf;
    std::vector<std::string>   labels;
    uint64_t                   epoch;
};

TiResult ti_device_set_pass_profiling(TiDevice *dev, bool enable) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!enable) { dev->profiling.store(false); return TI_OK; }
    @autoreleasepool {
        if (!dev->prof) {
            if (![dev->mtl supportsCounterSampling:MTLCounterSamplingPointAtStageBoundary])
                return ti_fail(TI_ERR_UNSUPPORTED, "GPU cannot sample counters at stage boundaries");
            id<MTLCounterSet> ts = nil;
            for (id<MTLCounterSet> cs in dev->mtl.counterSets)
                if ([cs.name isEqualToString:MTLCommonCounterSetTimestamp]) { ts = cs; break; }
            if (!ts) return ti_fail(TI_ERR_UNSUPPORTED, "no timestamp counter set on this GPU");
            TiProfiler *p = new TiProfiler();
            p->timestamps = ts;
            MTLTimestamp cpu = 0;
            [dev->mtl sampleTimestamps:&cpu gpuTimestamp:&p->gpu0];
            p->ns0 = ti_mono_ns();
            dev->prof = p;
        }
        dev->profiling.store(true);
        return TI_OK;
    }
}

void ti_device_reset_pass_profile(TiDevice *dev) {
    if (!ti_validate(dev, TI_T_DEVICE) || !dev->prof) return;
    std::lock_guard<std::mutex> lk(dev->prof->mtx);
    dev->prof->agg.clear();
    dev->prof->order.clear();
    dev->prof->cmdbufs = 0;
    dev->prof->unsampled.store(0);
    dev->prof->epoch.fetch_add(1);
}

void ti_profile_attach(TiFrame *f, MTLRenderPassDescriptor *rp, const char *label) {
    TiDevice *dev = f->dev;
    if (!dev->profiling.load(std::memory_order_relaxed) || !dev->prof) return;
    TiProfiler *p = dev->prof;
    if (!f->prof_buf) {
        std::lock_guard<std::mutex> lk(p->mtx);
        if (p->buffer_failed) return;
        if (!p->pool.empty()) {
            f->prof_buf = p->pool.back();
            p->pool.pop_back();
        } else {
            MTLCounterSampleBufferDescriptor *sd = [MTLCounterSampleBufferDescriptor new];
            sd.counterSet = p->timestamps;
            sd.storageMode = MTLStorageModeShared;
            sd.sampleCount = TI_PROF_SAMPLES;
            sd.label = @"Titanium.profile";
            NSError *err = nil;
            f->prof_buf = [dev->mtl newCounterSampleBufferWithDescriptor:sd error:&err];
            if (!f->prof_buf) {
                p->buffer_failed = true;   /* log once, then stay out of the way */
                ti_log(TI_LOG_WARN, "pass profiling disabled: sample buffer creation failed: %s",
                       err.localizedDescription.UTF8String ?: "?");
                return;
            }
        }
    }
    if (f->prof_labels.empty()) f->prof_epoch = p->epoch.load();
    NSUInteger base = (NSUInteger)f->prof_labels.size() * 4;
    if (base + 4 > TI_PROF_SAMPLES) { p->unsampled.fetch_add(1); return; }
    MTLRenderPassSampleBufferAttachmentDescriptor *sa = rp.sampleBufferAttachments[0];
    sa.sampleBuffer = f->prof_buf;
    sa.startOfVertexSampleIndex   = base;
    sa.endOfVertexSampleIndex     = base + 1;
    sa.startOfFragmentSampleIndex = base + 2;
    sa.endOfFragmentSampleIndex   = base + 3;
    f->prof_labels.emplace_back(label ? label : "(unlabelled)");
}

TiProfPending *ti_profile_take(TiFrame *f) {
    if (!f->prof_buf) return nullptr;
    TiProfPending *p = new TiProfPending();
    p->buf = f->prof_buf;
    p->labels.swap(f->prof_labels);
    p->epoch = f->prof_epoch;
    f->prof_buf = nil;
    return p;
}

/* A stage the driver did not sample reads back as MTLCounterErrorValue (or 0). */
static bool ti_span(uint64_t a, uint64_t b, uint64_t *out) {
    if (a == 0 || b == 0 || a == MTLCounterErrorValue || b == MTLCounterErrorValue || b < a) return false;
    *out = b - a;
    return true;
}

void ti_profile_complete(TiDevice *dev, TiProfPending *pend) {
    if (!pend) return;
    TiProfiler *p = dev->prof;
    @autoreleasepool {
        size_t n = pend->labels.size();
        NSData *data = n ? [pend->buf resolveCounterRange:NSMakeRange(0, n * 4)] : nil;
        const MTLCounterResultTimestamp *t =
            data && data.length >= n * 4 * sizeof(MTLCounterResultTimestamp)
                ? (const MTLCounterResultTimestamp *)data.bytes : nullptr;
        std::lock_guard<std::mutex> lk(p->mtx);
        if (t && pend->epoch == p->epoch.load()) {
            for (size_t i = 0; i < n; ++i) {
                auto it = p->agg.find(pend->labels[i]);
                if (it == p->agg.end()) {
                    p->order.push_back(pend->labels[i]);
                    it = p->agg.emplace(pend->labels[i], TiPassAgg{}).first;
                }
                TiPassAgg &a = it->second;
                uint64_t v = 0, fr = 0;
                bool okv = ti_span(t[4 * i].timestamp,     t[4 * i + 1].timestamp, &v);
                bool okf = ti_span(t[4 * i + 2].timestamp, t[4 * i + 3].timestamp, &fr);
                a.passes++;
                if (okv) a.vertex_ticks += v;
                if (okf) a.fragment_ticks += fr;
                if (!okv || !okf) a.invalid++;
            }
            p->cmdbufs++;
        }
        p->pool.push_back(pend->buf);
    }
    delete pend;
}

TiResult ti_device_pass_profile(TiDevice *dev, TiPassProfileEntry *out, uint32_t cap,
                                TiPassProfileSummary *summary) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (cap && !out) return TI_ERR_INVALID_ARGUMENT;
    TiProfiler *p = dev->prof;
    if (!p) return ti_fail(TI_ERR_INVALID_ARGUMENT, "pass profiling was never enabled");

    /* Calibrate over the whole interval since profiling began: long
     * baselines make the tick->ns ratio precise. */
    MTLTimestamp cpu = 0, gpu1 = 0;
    [dev->mtl sampleTimestamps:&cpu gpuTimestamp:&gpu1];
    uint64_t ns1 = ti_mono_ns();
    double ns_per_tick = 0;
    if (ns1 - p->ns0 >= 50000000ull && gpu1 > p->gpu0)
        ns_per_tick = (double)(ns1 - p->ns0) / (double)(gpu1 - p->gpu0);

    std::lock_guard<std::mutex> lk(p->mtx);
    uint32_t i = 0;
    for (; i < cap && i < p->order.size(); ++i) {
        const TiPassAgg &a = p->agg[p->order[i]];
        TiPassProfileEntry &e = out[i];
        memset(&e, 0, sizeof e);
        strlcpy(e.label, p->order[i].c_str(), sizeof e.label);
        e.passes = a.passes;
        e.invalid = a.invalid;
        e.vertex_ms   = ns_per_tick > 0 ? a.vertex_ticks   * ns_per_tick / 1e6 : NAN;
        e.fragment_ms = ns_per_tick > 0 ? a.fragment_ticks * ns_per_tick / 1e6 : NAN;
    }
    if (summary) {
        summary->command_buffers = p->cmdbufs;
        summary->unsampled_passes = p->unsampled.load();
        summary->ns_per_tick = ns_per_tick;
        summary->entries = (uint32_t)p->order.size();
    }
    return TI_OK;
}

void ti_profile_destroy(TiDevice *dev) {
    /* Called after the queue is idle: no completion handler can still run. */
    delete dev->prof;
    dev->prof = nullptr;
}
