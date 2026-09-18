/* Titanium — buffers, textures, samplers. */
#include "ti_internal.h"
#include <unistd.h>

/* ===================== buffers ======================================= */

static MTLResourceOptions ti_buffer_options(TiStorageMode m) {
    switch (m) {
        case TI_STORAGE_PRIVATE: return MTLResourceStorageModePrivate;
        case TI_STORAGE_SHARED:
        default:                 return MTLResourceStorageModeShared;
    }
}

TiResult ti_buffer_create(TiDevice *dev, uint64_t size, TiStorageMode mode,
                          const char *label, TiBuffer **out) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!out) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;
    if (size == 0) return ti_fail(TI_ERR_INVALID_ARGUMENT, "zero-length buffer");
    if (size > dev->caps.max_buffer_length)
        return ti_fail(TI_ERR_INVALID_ARGUMENT,
                       "buffer of %llu bytes exceeds device max %llu",
                       (unsigned long long)size,
                       (unsigned long long)dev->caps.max_buffer_length);
    /* MTLStorageModeMemoryless applies to render-target textures only. */
    if (mode == TI_STORAGE_MEMORYLESS)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "memoryless storage is not valid for buffers");

    @autoreleasepool {
        id<MTLBuffer> b = [dev->mtl newBufferWithLength:(NSUInteger)size
                                                options:ti_buffer_options(mode)];
        if (!b) return ti_fail(TI_ERR_OUT_OF_MEMORY, "newBufferWithLength(%llu) failed",
                               (unsigned long long)size);
        if (dev->debug_labels && label) b.label = [NSString stringWithUTF8String:label];

        TiBuffer *buf = new TiBuffer();
        buf->hdr = TiObjHeader TI_HDR_INIT(TI_T_BUFFER);
        buf->dev = dev; buf->mtl = b; buf->size = size; buf->mode = mode;
        *out = buf;
        return TI_OK;
    }
}

TiResult ti_buffer_create_no_copy(TiDevice *dev, void *ptr, uint64_t size,
                                  const char *label, TiBuffer **out) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!out || !ptr) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;

    /* newBufferWithBytesNoCopy requires page-aligned address and length.
     * On a discrete/non-unified device the aliasing would need a copy anyway,
     * so report UNSUPPORTED and let the caller fall back explicitly rather
     * than silently paying for a hidden copy. */
    if (!dev->caps.has_unified_memory)
        return ti_fail(TI_ERR_UNSUPPORTED, "no-copy buffers require unified memory");

    const uintptr_t page = (uintptr_t)getpagesize();
    if (((uintptr_t)ptr & (page - 1)) != 0)
        return ti_fail(TI_ERR_UNSUPPORTED, "pointer %p is not page-aligned", ptr);
    if ((size & (page - 1)) != 0)
        return ti_fail(TI_ERR_UNSUPPORTED, "length %llu is not a page multiple",
                       (unsigned long long)size);

    @autoreleasepool {
        /* Deallocator is nil: the caller (the JVM) continues to own the memory.
         * Callers must keep it alive until the buffer is released and all
         * frames referencing it have retired. */
        id<MTLBuffer> b = [dev->mtl newBufferWithBytesNoCopy:ptr
                                                     length:(NSUInteger)size
                                                    options:MTLResourceStorageModeShared
                                                deallocator:nil];
        if (!b) return ti_fail(TI_ERR_OUT_OF_MEMORY, "newBufferWithBytesNoCopy failed");
        if (dev->debug_labels && label) b.label = [NSString stringWithUTF8String:label];

        TiBuffer *buf = new TiBuffer();
        buf->hdr = TiObjHeader TI_HDR_INIT(TI_T_BUFFER);
        buf->dev = dev; buf->mtl = b; buf->size = size; buf->mode = TI_STORAGE_SHARED;
        *out = buf;
        return TI_OK;
    }
}

void ti_buffer_release(TiBuffer *b) {
    if (!ti_validate(b, TI_T_BUFFER)) return;
    b->hdr.magic = 0;
    b->mtl = nil;
    delete b;
}

void *ti_buffer_contents(TiBuffer *b) {
    TI_CHECK_NULL(b, TI_T_BUFFER);
    if (b->mode == TI_STORAGE_PRIVATE) return nullptr;
    return b->mtl.contents;
}

uint64_t ti_buffer_size(TiBuffer *b) {
    if (!ti_validate(b, TI_T_BUFFER)) return 0;
    return b->size;
}

TiResult ti_buffer_upload(TiBuffer *b, uint64_t offset, const void *src, uint64_t size) {
    TI_CHECK(b, TI_T_BUFFER);
    if (!src) return TI_ERR_INVALID_ARGUMENT;
    if (offset + size > b->size)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "upload [%llu,%llu) exceeds buffer size %llu",
                       (unsigned long long)offset, (unsigned long long)(offset + size),
                       (unsigned long long)b->size);
    if (size == 0) return TI_OK;

    if (b->mode == TI_STORAGE_SHARED) {
        /* Unified memory: a direct write, no staging buffer and no blit. */
        memcpy((uint8_t *)b->mtl.contents + offset, src, (size_t)size);
        return TI_OK;
    }

    @autoreleasepool {
        TiDevice *dev = b->dev;
        id<MTLBuffer> staging = [dev->mtl newBufferWithBytes:src
                                                      length:(NSUInteger)size
                                                     options:MTLResourceStorageModeShared];
        if (!staging) return ti_fail(TI_ERR_OUT_OF_MEMORY, "staging buffer allocation failed");

        id<MTLCommandBuffer> cb = [dev->queue commandBuffer];
        cb.label = @"Titanium.bufferUpload";
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromBuffer:staging sourceOffset:0
                    toBuffer:b->mtl destinationOffset:(NSUInteger)offset
                        size:(NSUInteger)size];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) return ti_fail(TI_ERR_INTERNAL, "buffer upload failed: %s",
                                     cb.error.localizedDescription.UTF8String ?: "?");
        return TI_OK;
    }
}

/* ===================== textures ====================================== */

TiResult ti_texture_create(TiDevice *dev, const TiTextureDesc *d, TiTexture **out) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!out || !d) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;

    MTLPixelFormat pf = ti_mtl_format(d->format);
    if (pf == MTLPixelFormatInvalid)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "unsupported pixel format %d", (int)d->format);
    if (d->width == 0 || d->height == 0)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "zero-sized texture");
    if (d->width > dev->caps.max_texture_size_2d || d->height > dev->caps.max_texture_size_2d)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "texture %ux%u exceeds device limit %u",
                       d->width, d->height, dev->caps.max_texture_size_2d);
    if (d->storage == TI_STORAGE_MEMORYLESS) {
        if (!dev->caps.supports_memoryless_targets)
            return ti_fail(TI_ERR_UNSUPPORTED, "memoryless attachments need a TBDR (Apple) GPU");
        if (!d->render_target)
            return ti_fail(TI_ERR_INVALID_ARGUMENT, "memoryless textures must be render targets");
        if (d->shader_read || d->shader_write)
            return ti_fail(TI_ERR_INVALID_ARGUMENT,
                           "memoryless textures cannot be sampled or written by shaders");
    }

    @autoreleasepool {
        MTLTextureDescriptor *td = [MTLTextureDescriptor new];
        td.pixelFormat = pf;
        td.width  = d->width;
        td.height = d->height;
        td.mipmapLevelCount = d->mip_levels ? d->mip_levels : 1;
        td.sampleCount = d->sample_count ? d->sample_count : 1;
        td.arrayLength = d->array_length ? d->array_length : 1;
        td.textureType = (td.sampleCount > 1)
            ? MTLTextureType2DMultisample
            : (td.arrayLength > 1 ? MTLTextureType2DArray : MTLTextureType2D);

        MTLTextureUsage usage = 0;
        if (d->render_target) usage |= MTLTextureUsageRenderTarget;
        if (d->shader_read)   usage |= MTLTextureUsageShaderRead;
        if (d->shader_write)  usage |= MTLTextureUsageShaderWrite;
        if (usage == 0)       usage = MTLTextureUsageShaderRead;
        td.usage = usage;

        switch (d->storage) {
            case TI_STORAGE_PRIVATE:    td.storageMode = MTLStorageModePrivate;    break;
            case TI_STORAGE_MEMORYLESS: td.storageMode = MTLStorageModeMemoryless; break;
            default:                    td.storageMode = MTLStorageModeShared;     break;
        }

        id<MTLTexture> t = [dev->mtl newTextureWithDescriptor:td];
        if (!t) return ti_fail(TI_ERR_OUT_OF_MEMORY, "newTextureWithDescriptor %ux%u failed",
                               d->width, d->height);
        if (dev->debug_labels && d->label) t.label = [NSString stringWithUTF8String:d->label];

        TiTexture *tex = new TiTexture();
        tex->hdr = TiObjHeader TI_HDR_INIT(TI_T_TEXTURE);
        tex->dev = dev; tex->mtl = t; tex->format = d->format;
        tex->mode = d->storage; tex->width = d->width; tex->height = d->height;
        *out = tex;
        return TI_OK;
    }
}

void ti_texture_release(TiTexture *t) {
    if (!ti_validate(t, TI_T_TEXTURE)) return;
    t->hdr.magic = 0;
    t->mtl = nil;
    delete t;
}

void ti_texture_dimensions(TiTexture *t, uint32_t *w, uint32_t *h) {
    if (!ti_validate(t, TI_T_TEXTURE)) return;
    if (w) *w = t->width;
    if (h) *h = t->height;
}

TiResult ti_texture_upload(TiTexture *t, uint32_t mip, uint32_t slice,
                           uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                           const void *src, uint32_t src_row_bytes) {
    TI_CHECK(t, TI_T_TEXTURE);
    if (!src || w == 0 || h == 0) return TI_ERR_INVALID_ARGUMENT;
    if (t->mode == TI_STORAGE_MEMORYLESS)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "cannot upload to a memoryless texture");

    MTLRegion region = MTLRegionMake2D(x, y, w, h);

    if (t->mode == TI_STORAGE_SHARED) {
        [t->mtl replaceRegion:region mipmapLevel:mip slice:slice
                    withBytes:src bytesPerRow:src_row_bytes bytesPerImage:0];
        return TI_OK;
    }

    @autoreleasepool {
        TiDevice *dev = t->dev;
        NSUInteger total = (NSUInteger)src_row_bytes * h;
        id<MTLBuffer> staging = [dev->mtl newBufferWithBytes:src length:total
                                                     options:MTLResourceStorageModeShared];
        if (!staging) return ti_fail(TI_ERR_OUT_OF_MEMORY, "texture staging allocation failed");

        id<MTLCommandBuffer> cb = [dev->queue commandBuffer];
        cb.label = @"Titanium.textureUpload";
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromBuffer:staging sourceOffset:0
               sourceBytesPerRow:src_row_bytes sourceBytesPerImage:total
                      sourceSize:MTLSizeMake(w, h, 1)
                       toTexture:t->mtl destinationSlice:slice destinationLevel:mip
               destinationOrigin:MTLOriginMake(x, y, 0)];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) return ti_fail(TI_ERR_INTERNAL, "texture upload failed: %s",
                                     cb.error.localizedDescription.UTF8String ?: "?");
        return TI_OK;
    }
}

TiResult ti_texture_readback(TiTexture *t, uint32_t mip,
                             uint32_t x, uint32_t y, uint32_t w, uint32_t h,
                             void *dst, uint32_t dst_row_bytes) {
    TI_CHECK(t, TI_T_TEXTURE);
    if (!dst || w == 0 || h == 0) return TI_ERR_INVALID_ARGUMENT;
    if (t->mode == TI_STORAGE_MEMORYLESS)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "memoryless textures cannot be read back");

    @autoreleasepool {
        TiDevice *dev = t->dev;
        /* Always route through a blit into shared storage. Commands on one
         * queue retire in submission order, so this observes all previously
         * committed rendering without extra synchronisation. */
        NSUInteger row = dst_row_bytes;
        NSUInteger total = row * h;
        id<MTLBuffer> staging = [dev->mtl newBufferWithLength:total
                                                      options:MTLResourceStorageModeShared];
        if (!staging) return ti_fail(TI_ERR_OUT_OF_MEMORY, "readback staging allocation failed");

        id<MTLCommandBuffer> cb = [dev->queue commandBuffer];
        cb.label = @"Titanium.readback";
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit copyFromTexture:t->mtl sourceSlice:0 sourceLevel:mip
                 sourceOrigin:MTLOriginMake(x, y, 0)
                   sourceSize:MTLSizeMake(w, h, 1)
                     toBuffer:staging destinationOffset:0
            destinationBytesPerRow:row destinationBytesPerImage:total];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) return ti_fail(TI_ERR_INTERNAL, "readback failed: %s",
                                     cb.error.localizedDescription.UTF8String ?: "?");
        memcpy(dst, staging.contents, total);
        return TI_OK;
    }
}

TiResult ti_texture_generate_mipmaps(TiTexture *t) {
    TI_CHECK(t, TI_T_TEXTURE);
    if (t->mtl.mipmapLevelCount <= 1) return TI_OK;
    @autoreleasepool {
        id<MTLCommandBuffer> cb = [t->dev->queue commandBuffer];
        cb.label = @"Titanium.genMips";
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        [blit generateMipmapsForTexture:t->mtl];
        [blit endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) return ti_fail(TI_ERR_INTERNAL, "mipmap generation failed: %s",
                                     cb.error.localizedDescription.UTF8String ?: "?");
        return TI_OK;
    }
}

/* ===================== samplers ====================================== */

static MTLSamplerMinMagFilter ti_min_mag(TiFilter f) {
    return f == TI_FILTER_LINEAR ? MTLSamplerMinMagFilterLinear
                                 : MTLSamplerMinMagFilterNearest;
}
static MTLSamplerMipFilter ti_mip(TiMipFilter f) {
    switch (f) {
        case TI_MIP_NEAREST: return MTLSamplerMipFilterNearest;
        case TI_MIP_LINEAR:  return MTLSamplerMipFilterLinear;
        default:             return MTLSamplerMipFilterNotMipmapped;
    }
}
static MTLSamplerAddressMode ti_addr(TiAddressMode m) {
    switch (m) {
        case TI_ADDR_REPEAT:        return MTLSamplerAddressModeRepeat;
        case TI_ADDR_MIRROR_REPEAT: return MTLSamplerAddressModeMirrorRepeat;
        case TI_ADDR_CLAMP_TO_ZERO: return MTLSamplerAddressModeClampToZero;
        default:                    return MTLSamplerAddressModeClampToEdge;
    }
}

TiResult ti_sampler_create(TiDevice *dev, const TiSamplerDesc *d, TiSampler **out) {
    TI_CHECK(dev, TI_T_DEVICE);
    if (!out || !d) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;
    @autoreleasepool {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = ti_min_mag(d->min_filter);
        sd.magFilter = ti_min_mag(d->mag_filter);
        sd.mipFilter = ti_mip(d->mip_filter);
        sd.sAddressMode = ti_addr(d->address_u);
        sd.tAddressMode = ti_addr(d->address_v);
        sd.rAddressMode = ti_addr(d->address_w);
        uint32_t aniso = d->max_anisotropy ? d->max_anisotropy : 1;
        if (aniso > 16) aniso = 16;
        sd.maxAnisotropy = aniso;
        sd.lodMinClamp = d->lod_min;
        sd.lodMaxClamp = (d->lod_max > d->lod_min) ? d->lod_max : FLT_MAX;
        if (dev->debug_labels && d->label) sd.label = [NSString stringWithUTF8String:d->label];

        id<MTLSamplerState> s = [dev->mtl newSamplerStateWithDescriptor:sd];
        if (!s) return ti_fail(TI_ERR_INTERNAL, "newSamplerStateWithDescriptor failed");

        TiSampler *smp = new TiSampler();
        smp->hdr = TiObjHeader TI_HDR_INIT(TI_T_SAMPLER);
        smp->mtl = s;
        *out = smp;
        return TI_OK;
    }
}

void ti_sampler_release(TiSampler *s) {
    if (!ti_validate(s, TI_T_SAMPLER)) return;
    s->hdr.magic = 0;
    s->mtl = nil;
    delete s;
}
