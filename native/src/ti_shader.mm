/* Titanium — shader libraries, render pipelines, depth/stencil state. */
#include "ti_internal.h"

/* ===================== libraries ===================================== */

TiResult ti_library_from_source(TiDevice *dev, const char *msl,
                                const char *key, TiLibrary **out) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!out || !msl) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;

    @autoreleasepool {
        /* A precompiled .metallib next to the cache wins: loading one is far
         * cheaper than invoking the runtime MSL front end. Produced by
         * tools/precompile-shaders.sh at build time. */
        if (key && !dev->cache_dir.empty()) {
            NSString *lib = [NSString stringWithFormat:@"%s/msl/%s.metallib",
                                                       dev->cache_dir.c_str(), key];
            if ([NSFileManager.defaultManager fileExistsAtPath:lib]) {
                NSError *e = nil;
                id<MTLLibrary> l = [dev->mtl newLibraryWithURL:[NSURL fileURLWithPath:lib]
                                                         error:&e];
                if (l) {
                    TiLibrary *L = new TiLibrary();
                    L->hdr = TiObjHeader TI_HDR_INIT(TI_T_LIBRARY);
                    L->dev = dev; L->mtl = l;
                    *out = L;
                    ti_log(TI_LOG_DEBUG, "library '%s' loaded from metallib", key);
                    return TI_OK;
                }
                ti_log(TI_LOG_WARN, "stale metallib for '%s' (%s); compiling from source",
                       key, e.localizedDescription.UTF8String ?: "?");
            }
        }

        MTLCompileOptions *opts = [MTLCompileOptions new];
        /* MSL 3.0 only exists from macOS 13. The translator targets MSL 2.3,
         * so 2.4 is sufficient everywhere; use 3.0 where it is available. */
        if (@available(macOS 13.0, *)) opts.languageVersion = MTLLanguageVersion3_0;
        else                           opts.languageVersion = MTLLanguageVersion2_4;

        NSError *err = nil;
        id<MTLLibrary> l = [dev->mtl newLibraryWithSource:[NSString stringWithUTF8String:msl]
                                                  options:opts error:&err];
        if (!l) {
            return ti_fail(TI_ERR_SHADER_COMPILE, "MSL compile failed for '%s': %s",
                           key ? key : "<anonymous>",
                           err.localizedDescription.UTF8String ?: "?");
        }
        /* Warnings still arrive in `err` even on success. */
        if (err && err.localizedDescription.length) {
            ti_log(TI_LOG_DEBUG, "MSL diagnostics for '%s': %s",
                   key ? key : "<anonymous>", err.localizedDescription.UTF8String);
        }
        if (dev->debug_labels && key) l.label = [NSString stringWithUTF8String:key];

        TiLibrary *L = new TiLibrary();
        L->hdr = TiObjHeader TI_HDR_INIT(TI_T_LIBRARY);
        L->dev = dev; L->mtl = l;
        *out = L;
        return TI_OK;
    }
}

TiResult ti_library_from_metallib(TiDevice *dev, const char *path, TiLibrary **out) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!out || !path) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;
    @autoreleasepool {
        NSError *err = nil;
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        id<MTLLibrary> l = [dev->mtl newLibraryWithURL:url error:&err];
        if (!l) return ti_fail(TI_ERR_IO, "cannot load metallib %s: %s", path,
                               err.localizedDescription.UTF8String ?: "?");
        TiLibrary *L = new TiLibrary();
        L->hdr = TiObjHeader TI_HDR_INIT(TI_T_LIBRARY);
        L->dev = dev; L->mtl = l;
        *out = L;
        return TI_OK;
    }
}

void ti_library_release(TiLibrary *l) {
    if (!ti_validate(l, TI_T_LIBRARY)) return;
    l->hdr.magic = 0;
    l->mtl = nil;
    delete l;
}

bool ti_library_has_function(TiLibrary *l, const char *name) {
    if (!ti_validate(l, TI_T_LIBRARY) || !name) return false;
    @autoreleasepool {
        return [l->mtl newFunctionWithName:[NSString stringWithUTF8String:name]] != nil;
    }
}

/* ===================== enum mapping ================================== */

/* Decodes TI_VF_MAKE(component, count, normalized). Every combination
 * Minecraft's VertexFormatElement can express maps to a native Metal format. */
static MTLVertexFormat ti_vf_encoded(uint32_t v) {
    uint32_t comp = (v >> 4) & 0xF, count = v & 0x7;
    bool norm = (v & 8) != 0;
    if (count < 1 || count > 4) return MTLVertexFormatInvalid;
    static const MTLVertexFormat f32[5] = { MTLVertexFormatInvalid, MTLVertexFormatFloat,
        MTLVertexFormatFloat2, MTLVertexFormatFloat3, MTLVertexFormatFloat4 };
    static const MTLVertexFormat u8[5]  = { MTLVertexFormatInvalid, MTLVertexFormatUChar,
        MTLVertexFormatUChar2, MTLVertexFormatUChar3, MTLVertexFormatUChar4 };
    static const MTLVertexFormat u8n[5] = { MTLVertexFormatInvalid, MTLVertexFormatUCharNormalized,
        MTLVertexFormatUChar2Normalized, MTLVertexFormatUChar3Normalized, MTLVertexFormatUChar4Normalized };
    static const MTLVertexFormat s8[5]  = { MTLVertexFormatInvalid, MTLVertexFormatChar,
        MTLVertexFormatChar2, MTLVertexFormatChar3, MTLVertexFormatChar4 };
    static const MTLVertexFormat s8n[5] = { MTLVertexFormatInvalid, MTLVertexFormatCharNormalized,
        MTLVertexFormatChar2Normalized, MTLVertexFormatChar3Normalized, MTLVertexFormatChar4Normalized };
    static const MTLVertexFormat u16[5] = { MTLVertexFormatInvalid, MTLVertexFormatUShort,
        MTLVertexFormatUShort2, MTLVertexFormatUShort3, MTLVertexFormatUShort4 };
    static const MTLVertexFormat u16n[5]= { MTLVertexFormatInvalid, MTLVertexFormatUShortNormalized,
        MTLVertexFormatUShort2Normalized, MTLVertexFormatUShort3Normalized, MTLVertexFormatUShort4Normalized };
    static const MTLVertexFormat s16[5] = { MTLVertexFormatInvalid, MTLVertexFormatShort,
        MTLVertexFormatShort2, MTLVertexFormatShort3, MTLVertexFormatShort4 };
    static const MTLVertexFormat s16n[5]= { MTLVertexFormatInvalid, MTLVertexFormatShortNormalized,
        MTLVertexFormatShort2Normalized, MTLVertexFormatShort3Normalized, MTLVertexFormatShort4Normalized };
    static const MTLVertexFormat u32[5] = { MTLVertexFormatInvalid, MTLVertexFormatUInt,
        MTLVertexFormatUInt2, MTLVertexFormatUInt3, MTLVertexFormatUInt4 };
    static const MTLVertexFormat s32[5] = { MTLVertexFormatInvalid, MTLVertexFormatInt,
        MTLVertexFormatInt2, MTLVertexFormatInt3, MTLVertexFormatInt4 };
    switch (comp) {
        case TI_VC_FLOAT:  return norm ? MTLVertexFormatInvalid : f32[count];
        case TI_VC_UBYTE:  return norm ? u8n[count]  : u8[count];
        case TI_VC_BYTE:   return norm ? s8n[count]  : s8[count];
        case TI_VC_USHORT: return norm ? u16n[count] : u16[count];
        case TI_VC_SHORT:  return norm ? s16n[count] : s16[count];
        case TI_VC_UINT:   return norm ? MTLVertexFormatInvalid : u32[count];
        case TI_VC_INT:    return norm ? MTLVertexFormatInvalid : s32[count];
        default:           return MTLVertexFormatInvalid;
    }
}

MTLVertexFormat ti_mtl_vertex_format(TiVertexFormat f);

static MTLVertexFormat ti_vf(TiVertexFormat f) {
    if ((uint32_t)f & 0x1000) return ti_vf_encoded((uint32_t)f);
    switch (f) {
        case TI_VF_FLOAT1:      return MTLVertexFormatFloat;
        case TI_VF_FLOAT2:      return MTLVertexFormatFloat2;
        case TI_VF_FLOAT3:      return MTLVertexFormatFloat3;
        case TI_VF_FLOAT4:      return MTLVertexFormatFloat4;
        case TI_VF_UCHAR4_NORM: return MTLVertexFormatUChar4Normalized;
        case TI_VF_UCHAR4:      return MTLVertexFormatUChar4;
        case TI_VF_CHAR4_NORM:  return MTLVertexFormatChar4Normalized;
        case TI_VF_SHORT2:      return MTLVertexFormatShort2;
        case TI_VF_SHORT2_NORM: return MTLVertexFormatShort2Normalized;
        case TI_VF_USHORT2:     return MTLVertexFormatUShort2;
        case TI_VF_UINT1:       return MTLVertexFormatUInt;
        default:                return MTLVertexFormatInvalid;
    }
}

static MTLBlendFactor ti_bf(TiBlendFactor f) {
    switch (f) {
        case TI_BF_ZERO:                     return MTLBlendFactorZero;
        case TI_BF_ONE:                      return MTLBlendFactorOne;
        case TI_BF_SRC_COLOR:                return MTLBlendFactorSourceColor;
        case TI_BF_ONE_MINUS_SRC_COLOR:      return MTLBlendFactorOneMinusSourceColor;
        case TI_BF_SRC_ALPHA:                return MTLBlendFactorSourceAlpha;
        case TI_BF_ONE_MINUS_SRC_ALPHA:      return MTLBlendFactorOneMinusSourceAlpha;
        case TI_BF_DST_COLOR:                return MTLBlendFactorDestinationColor;
        case TI_BF_ONE_MINUS_DST_COLOR:      return MTLBlendFactorOneMinusDestinationColor;
        case TI_BF_DST_ALPHA:                return MTLBlendFactorDestinationAlpha;
        case TI_BF_ONE_MINUS_DST_ALPHA:      return MTLBlendFactorOneMinusDestinationAlpha;
        case TI_BF_SRC_ALPHA_SATURATED:      return MTLBlendFactorSourceAlphaSaturated;
        case TI_BF_CONSTANT_COLOR:           return MTLBlendFactorBlendColor;
        case TI_BF_ONE_MINUS_CONSTANT_COLOR: return MTLBlendFactorOneMinusBlendColor;
        case TI_BF_CONSTANT_ALPHA:           return MTLBlendFactorBlendAlpha;
        case TI_BF_ONE_MINUS_CONSTANT_ALPHA: return MTLBlendFactorOneMinusBlendAlpha;
        default:                             return MTLBlendFactorOne;
    }
}

static MTLBlendOperation ti_bo(TiBlendOp o) {
    switch (o) {
        case TI_BO_SUBTRACT:         return MTLBlendOperationSubtract;
        case TI_BO_REVERSE_SUBTRACT: return MTLBlendOperationReverseSubtract;
        case TI_BO_MIN:              return MTLBlendOperationMin;
        case TI_BO_MAX:              return MTLBlendOperationMax;
        default:                     return MTLBlendOperationAdd;
    }
}

/* Public API uses 1=R 2=G 4=B 8=A; Metal's bit order is the reverse. */
static MTLColorWriteMask ti_write_mask(uint32_t m) {
    MTLColorWriteMask r = MTLColorWriteMaskNone;
    if (m & 1u) r |= MTLColorWriteMaskRed;
    if (m & 2u) r |= MTLColorWriteMaskGreen;
    if (m & 4u) r |= MTLColorWriteMaskBlue;
    if (m & 8u) r |= MTLColorWriteMaskAlpha;
    return r;
}

static MTLCompareFunction ti_cmp(TiCompareFunc c) {
    switch (c) {
        case TI_CMP_NEVER:    return MTLCompareFunctionNever;
        case TI_CMP_LESS:     return MTLCompareFunctionLess;
        case TI_CMP_EQUAL:    return MTLCompareFunctionEqual;
        case TI_CMP_LEQUAL:   return MTLCompareFunctionLessEqual;
        case TI_CMP_GREATER:  return MTLCompareFunctionGreater;
        case TI_CMP_NOTEQUAL: return MTLCompareFunctionNotEqual;
        case TI_CMP_GEQUAL:   return MTLCompareFunctionGreaterEqual;
        default:              return MTLCompareFunctionAlways;
    }
}

MTLVertexFormat ti_mtl_vertex_format(TiVertexFormat f) { return ti_vf(f); }

/* ===================== pipelines ===================================== */

TiResult ti_pipeline_create(TiDevice *dev, const TiPipelineDesc *d, TiPipeline **out) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!out || !d) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;
    if (!ti_validate(d->library, TI_T_LIBRARY)) return TI_ERR_INVALID_HANDLE;
    if (!d->vertex_fn) return ti_fail(TI_ERR_INVALID_ARGUMENT, "pipeline needs a vertex function");

    @autoreleasepool {
        id<MTLLibrary> lib = d->library->mtl;

        id<MTLFunction> vfn = [lib newFunctionWithName:[NSString stringWithUTF8String:d->vertex_fn]];
        if (!vfn) return ti_fail(TI_ERR_PIPELINE_CREATE, "vertex function '%s' not found",
                                 d->vertex_fn);
        id<MTLFunction> ffn = nil;
        if (d->fragment_fn) {
            id<MTLLibrary> flib = lib;
            if (d->fragment_library) {
                if (!ti_validate(d->fragment_library, TI_T_LIBRARY)) return TI_ERR_INVALID_HANDLE;
                flib = d->fragment_library->mtl;
            }
            ffn = [flib newFunctionWithName:[NSString stringWithUTF8String:d->fragment_fn]];
            if (!ffn) return ti_fail(TI_ERR_PIPELINE_CREATE, "fragment function '%s' not found",
                                     d->fragment_fn);
        }

        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = vfn;
        pd.fragmentFunction = ffn;
        pd.rasterSampleCount = d->sample_count ? d->sample_count : 1;
        pd.alphaToCoverageEnabled = d->alpha_to_coverage;
        if (d->label) pd.label = [NSString stringWithUTF8String:d->label];

        /* Vertex layout */
        if (d->attr_count) {
            MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
            for (uint32_t i = 0; i < d->attr_count; ++i) {
                const TiVertexAttr *a = &d->attrs[i];
                MTLVertexFormat vf = ti_vf(a->format);
                if (vf == MTLVertexFormatInvalid)
                    return ti_fail(TI_ERR_INVALID_ARGUMENT,
                                   "attribute %u has invalid vertex format %d",
                                   a->location, (int)a->format);
                vd.attributes[a->location].format = vf;
                vd.attributes[a->location].offset = a->offset;
                vd.attributes[a->location].bufferIndex = a->buffer;
            }
            for (uint32_t i = 0; i < d->layout_count; ++i) {
                const TiVertexBufferLayout *l = &d->layouts[i];
                if (l->stride == 0) continue;
                vd.layouts[i].stride = l->stride;
                vd.layouts[i].stepFunction = (l->step == TI_STEP_PER_INSTANCE)
                    ? MTLVertexStepFunctionPerInstance
                    : MTLVertexStepFunctionPerVertex;
                vd.layouts[i].stepRate = l->step_rate ? l->step_rate : 1;
            }
            pd.vertexDescriptor = vd;
        }

        /* Colour attachments */
        for (uint32_t i = 0; i < d->color_count && i < 8; ++i) {
            const TiColorTargetDesc *c = &d->color[i];
            MTLPixelFormat pf = ti_mtl_format(c->format);
            if (pf == MTLPixelFormatInvalid)
                return ti_fail(TI_ERR_INVALID_ARGUMENT,
                               "colour attachment %u has invalid format", i);
            MTLRenderPipelineColorAttachmentDescriptor *ca = pd.colorAttachments[i];
            ca.pixelFormat = pf;
            ca.writeMask = ti_write_mask(c->write_mask);
            ca.blendingEnabled = c->blend_enabled;
            if (c->blend_enabled) {
                ca.sourceRGBBlendFactor        = ti_bf(c->src_rgb);
                ca.destinationRGBBlendFactor   = ti_bf(c->dst_rgb);
                ca.sourceAlphaBlendFactor      = ti_bf(c->src_alpha);
                ca.destinationAlphaBlendFactor = ti_bf(c->dst_alpha);
                ca.rgbBlendOperation           = ti_bo(c->op_rgb);
                ca.alphaBlendOperation         = ti_bo(c->op_alpha);
            }
        }

        if (d->depth_format != TI_PF_INVALID)
            pd.depthAttachmentPixelFormat = ti_mtl_format(d->depth_format);
        if (d->stencil_format != TI_PF_INVALID)
            pd.stencilAttachmentPixelFormat = ti_mtl_format(d->stencil_format);

        /* Consult the on-disk binary archive first. A miss is not an error —
         * Metal falls back to compiling, and we then add the result so the
         * next run is warm. */
        id<MTLBinaryArchive> archive = nil;
        { std::lock_guard<std::mutex> lk(dev->archive_mtx); archive = dev->archive; }
        if (archive) pd.binaryArchives = @[archive];

        NSError *err = nil;
        id<MTLRenderPipelineState> ps = [dev->mtl newRenderPipelineStateWithDescriptor:pd
                                                                                error:&err];
        if (!ps) {
            return ti_fail(TI_ERR_PIPELINE_CREATE, "pipeline '%s' failed: %s",
                           d->label ? d->label : "<unnamed>",
                           err.localizedDescription.UTF8String ?: "?");
        }

        if (archive) {
            pd.binaryArchives = nil;
            NSError *ae = nil;
            std::lock_guard<std::mutex> lk(dev->archive_mtx);
            if ([archive addRenderPipelineFunctionsWithDescriptor:pd error:&ae]) {
                dev->archive_dirty = true;
            } else {
                ti_log(TI_LOG_DEBUG, "pipeline not added to cache: %s",
                       ae.localizedDescription.UTF8String ?: "?");
            }
        }

        TiPipeline *p = new TiPipeline();
        p->hdr = TiObjHeader TI_HDR_INIT(TI_T_PIPELINE);
        p->mtl = ps;
        *out = p;
        return TI_OK;
    }
}

void ti_pipeline_release(TiPipeline *p) {
    if (!ti_validate(p, TI_T_PIPELINE)) return;
    p->hdr.magic = 0;
    p->mtl = nil;
    delete p;
}

/* ===================== depth / stencil =============================== */

TiResult ti_depth_stencil_create(TiDevice *dev, const TiDepthStencilDesc *d,
                                 TiDepthStencil **out) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!out || !d) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;
    @autoreleasepool {
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = ti_cmp(d->depth_compare);
        dd.depthWriteEnabled = d->depth_write;
        if (dev->debug_labels && d->label) dd.label = [NSString stringWithUTF8String:d->label];

        id<MTLDepthStencilState> s = [dev->mtl newDepthStencilStateWithDescriptor:dd];
        if (!s) return ti_fail(TI_ERR_INTERNAL, "newDepthStencilStateWithDescriptor failed");

        TiDepthStencil *ds = new TiDepthStencil();
        ds->hdr = TiObjHeader TI_HDR_INIT(TI_T_DEPTHSTENCIL);
        ds->mtl = s;
        *out = ds;
        return TI_OK;
    }
}

void ti_depth_stencil_release(TiDepthStencil *ds) {
    if (!ti_validate(ds, TI_T_DEPTHSTENCIL)) return;
    ds->hdr.magic = 0;
    ds->mtl = nil;
    delete ds;
}
