/* Encoding-cost microbenchmark: what does the CPU pay per terrain-style draw?
 *
 * Minecraft draws each visible chunk section as its own indexed draw with its
 * own vertex buffer (thousands per frame at high render distance). This
 * measures, with raw Metal and no JNI, the CPU cost of encoding N such draws
 * under the variants a backend could choose between, so an optimisation is
 * picked from numbers rather than folklore:
 *
 *   A  setVertexBuffer(new buffer) + drawIndexed          (what Titanium does)
 *   B  as A, buffers created with hazard tracking off
 *   C  as A, buffers sub-allocated from one MTLHeap (untracked) + useHeap
 *   D  one big buffer, setVertexBufferOffset per draw + drawIndexed
 *   E  one big buffer, drawIndexed with baseVertex only (no per-draw bind)
 *   F  drawIndexed only, same buffer every draw (floor: the draw call itself)
 *
 * Each variant encodes N draws into one render pass of a small target, commits
 * and waits (GPU work is trivial: zero-area triangles), and reports CPU ns per
 * draw for the encode calls only. Median of several runs.
 *
 *   ti_encode_bench [draws] [pollute_kb]
 *
 * pollute_kb > 0 walks that much of a large array between draws (untimed), the
 * way Minecraft's own per-section work runs between the backend's calls in a
 * real frame, so buffer objects are no longer cache-hot when bound.
 */
#import <Metal/Metal.h>
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <time.h>
#include <vector>

static uint64_t now_ns() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static const char *kMSL = R"(
#include <metal_stdlib>
using namespace metal;
struct V { float3 p [[attribute(0)]]; };
struct U { float4x4 m; };
vertex float4 vs(V v [[stage_in]], constant U &u [[buffer(0)]]) { return u.m * float4(v.p * 0.0, 1); }
fragment float4 fs() { return float4(1); }
)";

int main(int argc, char **argv) {
    @autoreleasepool {
        const int N = argc > 1 ? atoi(argv[1]) : 5000;       /* draws per pass */
        const size_t POLLUTE = (argc > 2 ? atoi(argv[2]) : 0) * 1024ul;
        std::vector<uint64_t> junk(POLLUTE ? (256ul << 20) / 8 : 1, 1);   /* 256 MB */
        size_t jpos = 0;
        volatile uint64_t jsink = 0;
        const int RUNS = 15;
        const int VERTS = 4 * 64;                             /* 64 quads per section */
        const NSUInteger VB_BYTES = VERTS * 28;               /* MC BLOCK format stride */

        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> q = [dev newCommandQueue];
        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kMSL] options:nil error:&err];
        if (!lib) { fprintf(stderr, "msl: %s\n", err.localizedDescription.UTF8String); return 1; }
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = MTLVertexFormatFloat3; vd.attributes[0].bufferIndex = 30;
        vd.layouts[30].stride = 28;
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
        pd.vertexDescriptor = vd;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:64 height:64 mipmapped:NO];
        td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> rt = [dev newTextureWithDescriptor:td];

        /* Sequential quad indices (0,1,2,2,3,0 ...) as Minecraft's shared buffer. */
        std::vector<uint16_t> idx;
        for (int qd = 0; qd < VERTS / 4; ++qd) {
            uint16_t b = qd * 4;
            uint16_t s[6] = { b, (uint16_t)(b + 1), (uint16_t)(b + 2), (uint16_t)(b + 2), (uint16_t)(b + 3), b };
            idx.insert(idx.end(), s, s + 6);
        }
        id<MTLBuffer> ib = [dev newBufferWithBytes:idx.data() length:idx.size() * 2 options:MTLResourceStorageModeShared];
        const NSUInteger INDEX_COUNT = idx.size();
        id<MTLBuffer> ubo = [dev newBufferWithLength:256 * N options:MTLResourceStorageModeShared];

        std::vector<id<MTLBuffer>> tracked, untracked, heaped;
        for (int i = 0; i < N; ++i) {
            tracked.push_back([dev newBufferWithLength:VB_BYTES options:MTLResourceStorageModeShared]);
            untracked.push_back([dev newBufferWithLength:VB_BYTES
                                                  options:MTLResourceStorageModeShared | MTLResourceHazardTrackingModeUntracked]);
        }
        MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
        hd.storageMode = MTLStorageModeShared;
        hd.size = (NSUInteger)N * ((VB_BYTES + 0xFFFF) & ~(NSUInteger)0xFFFF);
        id<MTLHeap> heap = [dev newHeapWithDescriptor:hd];
        for (int i = 0; i < N; ++i) heaped.push_back([heap newBufferWithLength:VB_BYTES options:MTLResourceStorageModeShared]);
        id<MTLBuffer> big = [dev newBufferWithLength:VB_BYTES * N options:MTLResourceStorageModeShared];

        auto run = [&](char variant) -> double {
            std::vector<double> per;
            for (int r = 0; r < RUNS; ++r) {
                @autoreleasepool {
                    id<MTLCommandBuffer> cb = [q commandBuffer];
                    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                    rp.colorAttachments[0].texture = rt;
                    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
                    [e setRenderPipelineState:ps];
                    if (variant == 'C') [e useHeap:heap stages:MTLRenderStageVertex];
                    if (variant == 'D' || variant == 'E' || variant == 'F') [e setVertexBuffer:big offset:0 atIndex:30];
                    uint64_t spent = 0;
                    uint64_t t0 = now_ns();
                    for (int i = 0; i < N; ++i) {
                        if (POLLUTE) {
                            uint64_t acc = 0;
                            for (size_t k = 0; k < POLLUTE / 8; k += 8) {    /* one load per 64-byte line */
                                acc += junk[jpos]; jpos = (jpos + 8) % junk.size();
                            }
                            jsink = jsink + acc;
                            t0 = now_ns();
                        }
                        [e setVertexBuffer:ubo offset:256 * i atIndex:0];   /* per-section uniforms */
                        switch (variant) {
                            case 'A': [e setVertexBuffer:tracked[i] offset:0 atIndex:30]; break;
                            case 'B': [e setVertexBuffer:untracked[i] offset:0 atIndex:30]; break;
                            case 'C': [e setVertexBuffer:heaped[i] offset:0 atIndex:30]; break;
                            case 'D': [e setVertexBufferOffset:VB_BYTES * i atIndex:30]; break;
                            default: break;
                        }
                        NSInteger base = variant == 'E' ? (NSInteger)VERTS * i : 0;
                        [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:INDEX_COUNT
                                       indexType:MTLIndexTypeUInt16 indexBuffer:ib indexBufferOffset:0
                                   instanceCount:1 baseVertex:base baseInstance:0];
                        if (POLLUTE) spent += now_ns() - t0;
                    }
                    uint64_t t1 = now_ns();
                    if (POLLUTE) { t0 = 0; t1 = spent; }
                    [e endEncoding];
                    [cb commit];
                    [cb waitUntilCompleted];
                    per.push_back((double)(t1 - t0) / N);
                }
            }
            std::sort(per.begin(), per.end());
            return per[per.size() / 2];
        };

        printf("%d draws/pass, median of %d passes, CPU ns per draw (encode calls only)%s\n", N, RUNS,
               POLLUTE ? ", cache polluted between draws" : "");
        struct { char v; const char *what; } vs[] = {
            { 'A', "setVertexBuffer(new buffer) + draw   [current]" },
            { 'B', "  same, hazard tracking off" },
            { 'C', "  same, buffers in one heap + useHeap" },
            { 'D', "one buffer, setVertexBufferOffset + draw" },
            { 'E', "one buffer, baseVertex only + draw" },
            { 'F', "draw only (floor)" },
        };
        for (int pass = 0; pass < 2; ++pass)       /* first pass warms everything up */
            for (auto &v : vs) {
                double ns = run(v.v);
                if (pass == 1) printf("  %c  %7.1f ns  %s\n", v.v, ns, v.what);
            }
    }
    return 0;
}
