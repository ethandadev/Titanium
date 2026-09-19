/* Titanium — world upscaling for decoupled resolution: MetalFX spatial where
 * available, bilinear otherwise. */
#include "ti_internal.h"
#import <MetalFX/MetalFX.h>

static TiResult ti_bilinear(TiFrame *f, id<MTLTexture> src, id<MTLTexture> dst) {
    id<MTLRenderPipelineState> ps = ti_internal_pipeline(f->dev, "ti_blit_vs", "ti_blit_fs",
                                                         dst.pixelFormat, MTLPixelFormatInvalid);
    if (!ps) return TI_ERR_PIPELINE_CREATE;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = dst;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;   /* fully overwritten */
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    ti_profile_attach(f, rp, "Titanium.upscale.bilinear");
    id<MTLRenderCommandEncoder> enc = [f->cmd renderCommandEncoderWithDescriptor:rp];
    enc.label = @"Titanium.upscale.bilinear";
    [enc setRenderPipelineState:ps];
    [enc setFragmentTexture:src atIndex:0];
    [enc setFragmentSamplerState:f->dev->smp_linear atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    return TI_OK;
}

TiResult ti_frame_upscale(TiFrame *f, TiTexture *src, TiTexture *dst, TiUpscaler mode) {
    TI_CHECK(f, TI_T_FRAME);
    TI_CHECK(src, TI_T_TEXTURE);
    TI_CHECK(dst, TI_T_TEXTURE);
    if (f->pass_open) return ti_fail(TI_ERR_INVALID_ARGUMENT, "upscale while a render pass is open");
    @autoreleasepool {
        /* Make sure the internal library (and its samplers) exist. */
        if (!ti_internal_pipeline(f->dev, "ti_blit_vs", "ti_blit_fs", dst->mtl.pixelFormat,
                                  MTLPixelFormatInvalid))
            return TI_ERR_PIPELINE_CREATE;

        if (mode == TI_UPSCALE_BILINEAR) return ti_bilinear(f, src->mtl, dst->mtl);

        if (@available(macOS 13.0, *)) {
            TiDevice *dev = f->dev;
            if (![MTLFXSpatialScalerDescriptor supportsDevice:dev->mtl])
                return ti_fail(TI_ERR_UNSUPPORTED, "MetalFX spatial scaling is not supported on this device");

            uint64_t key = ((uint64_t)src->mtl.width << 48) ^ ((uint64_t)src->mtl.height << 32) ^
                           ((uint64_t)dst->mtl.width << 16) ^ (uint64_t)dst->mtl.height ^
                           ((uint64_t)dst->mtl.pixelFormat << 56);
            if (!dev->fx_scaler || dev->fx_key != key) {
                MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
                d.inputWidth = src->mtl.width;   d.inputHeight = src->mtl.height;
                d.outputWidth = dst->mtl.width;  d.outputHeight = dst->mtl.height;
                d.colorTextureFormat = src->mtl.pixelFormat;
                d.outputTextureFormat = dst->mtl.pixelFormat;
                /* Minecraft's targets hold display-referred (sRGB-encoded) 8-bit
                 * values, i.e. perceptual, not linear, colour. */
                d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
                id<MTLFXSpatialScaler> s = [d newSpatialScalerWithDevice:dev->mtl];
                if (!s) return ti_fail(TI_ERR_INTERNAL, "MetalFX spatial scaler creation failed");
                dev->fx_scaler = s;
                dev->fx_key = key;
                dev->fx_intermediate = nil;
                if (!dev->fx_logged) {
                    ti_log(TI_LOG_INFO, "MetalFX spatial %lux%lu -> %lux%lu; required usage: input 0x%lx, output 0x%lx",
                           (unsigned long)d.inputWidth, (unsigned long)d.inputHeight,
                           (unsigned long)d.outputWidth, (unsigned long)d.outputHeight,
                           (unsigned long)s.colorTextureUsage, (unsigned long)s.outputTextureUsage);
                    dev->fx_logged = true;
                }
            }
            id<MTLFXSpatialScaler> s = (id<MTLFXSpatialScaler>)dev->fx_scaler;
            if ((src->mtl.usage & s.colorTextureUsage) != s.colorTextureUsage)
                return ti_fail(TI_ERR_UNSUPPORTED, "MetalFX input lacks required usage 0x%lx",
                               (unsigned long)s.colorTextureUsage);

            /* Write straight into dst when it has the usage MetalFX needs;
             * otherwise into a cached intermediate and blit-copy (same size and
             * format, so a plain copy). */
            id<MTLTexture> out = dst->mtl;
            if ((dst->mtl.usage & s.outputTextureUsage) != s.outputTextureUsage) {
                if (!dev->fx_intermediate) {
                    MTLTextureDescriptor *td = [MTLTextureDescriptor
                        texture2DDescriptorWithPixelFormat:dst->mtl.pixelFormat
                                                     width:dst->mtl.width height:dst->mtl.height
                                                 mipmapped:NO];
                    td.usage = s.outputTextureUsage | MTLTextureUsageShaderRead;
                    td.storageMode = MTLStorageModePrivate;
                    dev->fx_intermediate = [dev->mtl newTextureWithDescriptor:td];
                    if (!dev->fx_intermediate) return ti_fail(TI_ERR_OUT_OF_MEMORY, "MetalFX intermediate failed");
                }
                out = dev->fx_intermediate;
            }
            s.colorTexture = src->mtl;
            s.outputTexture = out;
            s.inputContentWidth = src->mtl.width;
            s.inputContentHeight = src->mtl.height;
            [s encodeToCommandBuffer:f->cmd];
            if (out != dst->mtl) {
                id<MTLBlitCommandEncoder> b = [f->cmd blitCommandEncoder];
                [b copyFromTexture:out toTexture:dst->mtl];
                [b endEncoding];
            }
            return TI_OK;
        }
        return ti_fail(TI_ERR_UNSUPPORTED, "MetalFX requires macOS 13");
    }
}
