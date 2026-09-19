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

/* Metal asserts (and aborts) on out-of-range texture regions; OpenGL raises an
 * error or treats a 0x0 level as a no-op. Returns TI_OK when the region is
 * valid, TI_NO_OP when it touches nothing (0x0 region or a level past the
 * clamped mip chain, which GL would have created as 0x0), else an error. */
TiResult ti_check_region(TiTexture *t, uint32_t mip, uint32_t slice,
                         uint32_t x, uint32_t y, uint32_t w, uint32_t h) {
    if (w == 0 || h == 0) return TI_NO_OP;
    if (mip >= t->mtl.mipmapLevelCount) return TI_NO_OP;
    uint32_t mw = (uint32_t)(t->mtl.width >> mip), mh = (uint32_t)(t->mtl.height >> mip);
    if (!mw) mw = 1;
    if (!mh) mh = 1;
    NSUInteger slices = (t->mtl.textureType == MTLTextureTypeCube) ? 6 : t->mtl.arrayLength;
    if (slice >= slices)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "slice %u out of range (%lu)", slice, (unsigned long)slices);
    if ((uint64_t)x + w > mw || (uint64_t)y + h > mh)
        return ti_fail(TI_ERR_INVALID_ARGUMENT,
                       "region %ux%u at (%u,%u) exceeds mip %u size %ux%u", w, h, x, y, mip, mw, mh);
    return TI_OK;
}

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
        /* OpenGL lets a caller define mip levels past 1x1 (they are simply
         * 0x0); Minecraft does this (e.g. a 16x16 texture with 6 levels).
         * Metal *aborts the process* on such a descriptor, so clamp to the
         * levels that can exist. Levels beyond it are 0x0 and hold no data. */
        {
            uint32_t maxdim = d->width > d->height ? d->width : d->height, full = 1;
            while (maxdim > 1) { maxdim >>= 1; ++full; }
            uint32_t want = d->mip_levels ? d->mip_levels : 1;
            td.mipmapLevelCount = want > full ? full : want;
        }
        td.sampleCount = d->sample_count ? d->sample_count : 1;
        td.arrayLength = d->array_length ? d->array_length : 1;
        if (d->cube) {
            if (td.arrayLength != 6 || d->width != d->height)
                return ti_fail(TI_ERR_INVALID_ARGUMENT,
                               "cube textures need 6 square faces (got %u layers, %ux%u)",
                               (unsigned)td.arrayLength, d->width, d->height);
            td.textureType = MTLTextureTypeCube;
            td.arrayLength = 1;           /* Metal: a cube is one "array element" */
        } else {
            td.textureType = (td.sampleCount > 1)
                ? MTLTextureType2DMultisample
                : (td.arrayLength > 1 ? MTLTextureType2DArray : MTLTextureType2D);
        }

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
    if (!src) return TI_ERR_INVALID_ARGUMENT;
    if (t->mode == TI_STORAGE_MEMORYLESS)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "cannot upload to a memoryless texture");
    { TiResult rr = ti_check_region(t, mip, slice, x, y, w, h); if (rr == TI_NO_OP) return TI_OK; if (rr != TI_OK) return rr; }

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
    if (!dst) return TI_ERR_INVALID_ARGUMENT;
    if (t->mode == TI_STORAGE_MEMORYLESS)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "memoryless textures cannot be read back");
    { TiResult rr = ti_check_region(t, mip, 0, x, y, w, h); if (rr == TI_NO_OP) return TI_OK; if (rr != TI_OK) return rr; }

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

TiResult ti_texture_create_view(TiTexture *t, uint32_t base_mip, uint32_t mip_count,
                                TiTexture **out) {
    TI_CHECK(t, TI_T_TEXTURE);
    if (!out) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;
    NSUInteger levels = t->mtl.mipmapLevelCount;
    if (mip_count == 0 || base_mip >= levels)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "view mips [%u,%u) outside texture's %lu",
                       base_mip, base_mip + mip_count, (unsigned long)levels);
    /* Requested levels past the clamped chain are 0x0 in GL terms; drop them. */
    if (base_mip + mip_count > levels) mip_count = (uint32_t)(levels - base_mip);
    @autoreleasepool {
        NSUInteger slices = (t->mtl.textureType == MTLTextureTypeCube) ? 6 : t->mtl.arrayLength;
        id<MTLTexture> v = [t->mtl newTextureViewWithPixelFormat:t->mtl.pixelFormat
                                                     textureType:t->mtl.textureType
                                                          levels:NSMakeRange(base_mip, mip_count)
                                                          slices:NSMakeRange(0, slices)];
        if (!v) return ti_fail(TI_ERR_INTERNAL, "newTextureViewWithPixelFormat failed");
        TiTexture *tex = new TiTexture();
        tex->hdr = TiObjHeader TI_HDR_INIT(TI_T_TEXTURE);
        tex->dev = t->dev; tex->mtl = v; tex->format = t->format; tex->mode = t->mode;
        tex->width = t->width >> base_mip; tex->height = t->height >> base_mip;
        if (!tex->width) tex->width = 1;
        if (!tex->height) tex->height = 1;
        *out = tex;
        return TI_OK;
    }
}

TiResult ti_texture_create_buffer_view(TiBuffer *b, TiPixelFormat fmt, uint64_t offset,
                                       uint64_t size_bytes, TiTexture **out) {
    TI_CHECK(b, TI_T_BUFFER);
    if (!out) return TI_ERR_INVALID_ARGUMENT;
    *out = nullptr;
    MTLPixelFormat pf = ti_mtl_format(fmt);
    uint32_t bpp = ti_pixel_format_bytes_per_pixel(fmt);
    if (pf == MTLPixelFormatInvalid || bpp == 0)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "unsupported texel-buffer format %d", (int)fmt);
    if (offset + size_bytes > b->size)
        return ti_fail(TI_ERR_INVALID_ARGUMENT, "texel-buffer range exceeds buffer");
    @autoreleasepool {
        TiDevice *dev = b->dev;
        NSUInteger align = [dev->mtl minimumTextureBufferAlignmentForPixelFormat:pf];
        if (align && (offset % align) != 0)
            return ti_fail(TI_ERR_INVALID_ARGUMENT, "texel-buffer offset %llu not aligned to %lu",
                           (unsigned long long)offset, (unsigned long)align);
        NSUInteger elements = (NSUInteger)(size_bytes / bpp);
        MTLTextureDescriptor *td =
            [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:pf
                                                                   width:elements
                                                         resourceOptions:b->mtl.resourceOptions
                                                                   usage:MTLTextureUsageShaderRead];
        NSUInteger row = elements * bpp;
        if (align) row = (row + align - 1) / align * align;
        id<MTLTexture> v = [b->mtl newTextureWithDescriptor:td offset:(NSUInteger)offset bytesPerRow:row];
        if (!v) return ti_fail(TI_ERR_INTERNAL, "texture-buffer view creation failed");
        TiTexture *tex = new TiTexture();
        tex->hdr = TiObjHeader TI_HDR_INIT(TI_T_TEXTURE);
        tex->dev = dev; tex->mtl = v; tex->format = fmt; tex->mode = TI_STORAGE_SHARED;
        tex->width = (uint32_t)elements; tex->height = 1;
        *out = tex;
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
        /* Negative means unbounded. Treating lod_max == lod_min as unbounded
         * (as an earlier version did) would let a maxLod of 0 sample every mip. */
        sd.lodMaxClamp = (d->lod_max < 0.0f) ? FLT_MAX : d->lod_max;
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
