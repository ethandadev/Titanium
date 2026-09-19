# Titanium — Architecture

How a Java game that speaks OpenGL ends up issuing Metal commands, and what
has to change in between.

---

## 1. Layering

```
Minecraft render code  (unchanged)
        │
        ▼
com.mojang.blaze3d.systems.GpuDevice / CommandEncoder / RenderPass   ← Mojang's seam
        │
        ▼
com.ethandadev.titanium.backend.*        Java: implements the seam
        │   (handles are longs; bulk data is direct ByteBuffers)
        ▼
libtitanium.dylib — JNI entry points     C ABI (ti_api.h)
        │
        ▼
Objective-C++ ── Metal
```

Two properties of this shape matter:

1. **One seam, not thousands of call sites.** 57 interface methods
   (`GpuDevice` 23, `CommandEncoder` 20, `RenderPass` 14) are the entire
   backend contract. Verified by `tools/verify-mc.sh`.
2. **The C ABI is FFM-shaped.** `ti_api.h` uses no C++ or Objective-C types in
   its signatures, so the Java 22+ `java.lang.foreign` binding can be added
   later beside the JNI one without touching native code.

### Why JNI today
Minecraft 1.21.11 declares `javaVersion.majorVersion = 21`. `java.lang.foreign`
is a *preview* API in Java 21 and only final in 22, so an FFM-based mod would
need `--enable-preview` on the launcher's own JRE. JNI needs no launch flags.
Verified by running the full JVM test suite on the launcher's bundled
OpenJDK 21.0.3.

### Call-rate design
JNI transitions are cheap but not free, and Minecraft issues thousands of draws
per frame. Two decisions keep the boundary from becoming the bottleneck:

- **Vertex data never crosses.** `ti_buffer_contents` returns a pointer that
  `NewDirectByteBuffer` wraps; on unified memory that is the same memory the GPU
  reads. Java writes vertices straight into it. Zero copies, zero per-vertex
  JNI calls. *(Verified: the returned `ByteBuffer` aliases the allocation.)*
- **Per-draw uniforms are inlined.** `setVertexBytes`/`setFragmentBytes` push
  ≤4 KiB directly into the command buffer rather than allocating a buffer per
  draw.

If profiling later shows per-draw JNI overhead dominating, the next step is a
command ring buffer in shared memory that Java fills and native drains at pass
end. That is deliberately **not** built yet — it would be speculative
optimisation ahead of a measurement.

---

## 2. Mapping Minecraft's concepts onto Metal

| Minecraft (blaze3d) | Metal |
|---|---|
| `GpuDevice` | `MTLDevice` + `MTLCommandQueue` |
| `CommandEncoder` | `MTLCommandBuffer` |
| `RenderPass` | `MTLRenderCommandEncoder` + `MTLRenderPassDescriptor` |
| `RenderPipeline` | `MTLRenderPipelineState` + `MTLDepthStencilState` |
| `GpuBuffer` | `MTLBuffer` |
| `GpuTexture` / `GpuTextureView` | `MTLTexture` / texture view |
| `GpuSampler` | `MTLSamplerState` |
| `GpuFence` | `MTLCommandBuffer` completion handler |
| `GpuQuery` (timer) | `GPUStartTime`/`GPUEndTime` |
| `presentTexture` | `CAMetalDrawable` present |
| `VertexFormat` | `MTLVertexDescriptor` |
| `BlendFunction` | colour-attachment blend state |
| `LogicOp` | **no equivalent — see §4.4** |

---

## 3. Shaders: how GLSL becomes MSL

Minecraft ships **93 GLSL files** (`#version 330`, std140 uniform blocks,
`#moj_import` includes), and a resource pack may replace any of them. Metal
cannot consume GLSL, and hand-writing MSL for the vanilla set would break the
moment a pack overrides a shader. So translation must happen at load time.

### Where the source comes from (verified, and a correction)

In-game, Titanium does **not** resolve `#moj_import` itself. Bytecode shows
`ShaderManager` already runs Mojang's `GlslPreprocessor.process` at
resource-load time, and `GlDevice` receives flattened text through
`ShaderSource.get(id, type)` and only calls the static
`GlslPreprocessor.injectDefines(String, ShaderDefines)`. Titanium's device does
exactly the same, calling Mojang's own `injectDefines`, so pack overrides and
define handling behave identically to vanilla.

Titanium's `GlslPreprocessor` (M2a) is therefore **not** on the in-game path.
It exists for offline work — the corpus tests and cache keys — where no
`ShaderManager` is running.

### Pipeline

```
Minecraft GLSL 330  ──#moj_import resolution (ShaderManager, in-game)──►  flattened GLSL
        │
        ├─ glslang  ──►  SPIR-V
        │
        ├─ SPIR-V reflection ──►  name → binding index map
        │
        └─ SPIRV-Cross ──►  MSL  ──►  MTLLibrary  ──►  MTLRenderPipelineState
                                           │
                                     cached on disk
```

**This is source translation, not an API translation layer.** No Vulkan driver
is loaded, no `VkDevice` exists, and MoltenVK is not involved. glslang and
SPIRV-Cross are compilers that run at load time; at runtime the process talks
only to Metal.

### Why reflection is required, not optional
`RenderPass` binds resources **by name**:

```java
void bindTexture(String name, GpuTextureView view, GpuSampler sampler);
void setUniform(String name, GpuBufferSlice buffer);
```

Metal binds by **numeric index**. SPIRV-Cross's reflection output supplies the
`name → (buffer|texture|sampler) index` mapping that bridges the two, computed
once per pipeline and cached alongside it. Without it, `bindTexture("Sampler0", …)`
has nowhere to go.

### Semantic fixups that must be applied
These are the differences that produce *silently wrong pixels* rather than
compile errors. Each is applied during translation and must be covered by a
golden-image test.

| # | Difference | Fixup |
|---|---|---|
| 3.1 | **Clip-space depth.** OpenGL NDC *z* ∈ [-1, 1]; Metal *z* ∈ [0, 1]. | Append `gl_Position.z = (gl_Position.z + gl_Position.w) * 0.5;` to every translated vertex shader. Without this, everything is depth-clipped or z-fights. |
| 3.2 | **Framebuffer origin.** OpenGL's render-target origin is bottom-left; Metal's is top-left. | Negate clip-space *y*. **This reverses triangle winding**, so the front-face winding passed to the encoder must be inverted in lockstep — otherwise face culling silently removes the wrong triangles. |
| 3.3 | **`gl_FragCoord`.** Measured from the bottom in GL, from the top in Metal. | **None needed — corrected.** An earlier draft proposed a height-based fix. Because 3.2 makes render targets keep GL's memory layout, Metal's `[[position]]` row index already equals GL's `gl_FragCoord.y`. *Verified by golden test 5.* |
| 3.4 | **std140 vs MSL layout.** A `float` after a `vec3` shares its 16-byte slot in std140; a naive MSL `float3` struct would push it to the next slot. | SPIRV-Cross emits the SPIR-V offsets faithfully. Block size is reported rounded up to 16, as std140 defines it (SPIRV-Cross's declared size stops at the last member). *Verified by golden test 8 with a vec3+float block.* |
| 3.5 | **`gl_VertexID` with a base vertex.** | **None needed — corrected.** An earlier draft claimed GL excludes the base vertex. That was wrong: OpenGL's `DrawElementsBaseVertex` defines `gl_VertexID` as index + basevertex, and Metal's `[[vertex_id]]` agrees. *Verified by golden test 7: indices 0,1,2 with base vertex 4 give 4,5,6.* |
| 3.6 | **Varyings link by name in GL.** glslang's `mapIO()` with the OpenGL client assigns locations per stage in *declaration order*, so a fragment shader declaring `(b, a)` against a vertex `(a, b)` would silently swap them. | Every fragment input is re-pointed at the vertex output of the same name. *Found by golden test 9, which failed before the fix.* |
| 3.7 | **GL tolerates declared-but-unused inputs.** Vanilla `rendertype_text_background.fsh` declares `texCoord0` and never reads it. Metal rejects a pipeline whose fragment stage_in expects something the vertex function never writes. | Only statically-used interface variables are emitted. A *used* unmatched input is still an error, as in GL. *Found by the corpus test.* |
| 3.8 | **GLSL identifiers that are MSL types.** Vanilla `terrain.fsh` has a parameter named `sampler`. | Renamed (`sampler_ti`) *after* reflection, so name-based binds still see the GLSL name. *Found by the corpus test; golden test 11.* |
| 3.9 | **Provoking vertex for `flat` varyings.** GL uses the **last** vertex of a primitive; Metal uses the **first**, and has no setting to change it. | **Open.** Exactly one vanilla pair uses `flat` (`rendertype_leash`), so the leash's alternating stripes would shift. Planned fix in M3: rotate indices for triangle lists (`a,b,c` → `c,a,b` keeps winding) for pipelines whose shaders use `flat`. |

### Metal binding scheme
Uniform blocks take buffer slots densely from 0, vertex data sits at slot 30
(`TI_VERTEX_BUFFER_INDEX`), and samplers are capped at Metal's 16 per stage.
OpenGL keeps UBO and texture bindings in separate namespaces, so glslang gives
the first UBO and the first sampler both binding 0; every resource is rebound
to a unique binding before Metal slots are assigned, so the mapping is never
ambiguous. A block or sampler used by both stages gets the same slot in both,
because Minecraft binds it once by name for the whole pipeline.

Texture coordinates need **no** flip: in both APIs UV (0,0) addresses the first
texel in memory. Only the *framebuffer* origin differs. Conflating the two is a
common way to produce upside-down render targets, so it is stated explicitly.

### Caching
- Translated MSL is cached on disk, keyed by a hash of (GLSL source + defines +
  backend version), so a resource-pack change invalidates exactly what changed.
- Compiled pipelines go into an `MTLBinaryArchive`, written atomically via a
  temp file + rename so a crash mid-write cannot corrupt the cache. A stale or
  driver-incompatible archive is detected and discarded rather than fatal.
  *(Implemented and tested.)*

---

## 4. Rendering semantics that are not shader-level

### 4.1 Depth formats
Apple GPUs report `depth24Stencil8PixelFormatSupported == false`. Requests for
`DEPTH24_STENCIL8` are served as `Depth32Float_Stencil8` — more precision, two
more bytes per pixel. *(Verified on M3 Max: the capability probe reports 0.)*

### 4.2 Uniform buffer offset alignment
`GpuDevice.getUniformOffsetAlignment()` must return a value Metal will accept
for `setVertexBuffer:offset:`. Metal exposes no query for this, so Titanium
returns a **conservative 256**. Over-reporting alignment only wastes a little
memory; under-reporting corrupts uniforms. The value will be tightened per GPU
family only once validated on hardware — not guessed.

### 4.3 Memoryless attachments (TBDR)
On Apple GPUs a depth buffer that is never sampled afterwards never needs to
exist in main memory: `MTLStorageModeMemoryless` keeps it in tile memory. The
render pass must then use `storeAction = DontCare`, which Titanium enforces
rather than letting Metal's validation layer abort the process.
*(Implemented and tested — the depth test in the native self-test runs against
a memoryless attachment.)*

### 4.4 `LogicOp` — the one hard gap (does not affect vanilla)
`RenderPipeline.getColorLogic()` exposes OpenGL logic-op blending. **Metal has
no fixed-function logic ops.** However, verified against the 1.21.11 sources:
**no vanilla pipeline sets a logic op** — `withColorLogic` has no callers, and
text-selection inversion (`GUI_INVERT`) uses `BlendFunction.INVERT`, which
Metal expresses natively. The gap therefore only affects third-party mods that
build logic-op pipelines. Handling:

- `LogicOp.NONE` (the overwhelmingly common case): unaffected.
- Otherwise, on Apple GPUs, emulate in the fragment shader via programmable
  blending, which can read the current colour attachment value.
- Where that is unavailable, **refuse the pipeline and report it** rather than
  rendering something subtly wrong.

---

## 5. Resource ownership and lifetime

- Every `ti_*_create` returns a handle the caller owns and releases with the
  matching `ti_*_release`. Java wrappers own exactly one handle each.
- Handles are pointers to tagged control blocks. Release **poisons the tag**, so
  a use-after-free returns `INVALID_HANDLE` instead of dereferencing freed
  memory. *(Tested: stale and foreign handles are rejected.)*
- `ti_buffer_create_no_copy` aliases JVM memory and takes **no** ownership. The
  caller must keep the allocation alive until the buffer is released *and* every
  frame referencing it has retired. This is the sharpest edge in the API and is
  why it refuses misaligned pointers rather than silently copying.
- `ti_device_release` flushes the pipeline cache and waits for the GPU to go
  idle before tearing anything down.

## 6. Synchronisation and frames in flight

A counting semaphore bounds the CPU to *N* frames ahead of the GPU (default 3,
matching `CAMetalLayer.maximumDrawableCount`). The token is released in the
command buffer's completion handler.

Two failure modes are handled explicitly:
- **Drawable timeout** (occluded, minimised, display reconfigured):
  `nextDrawable` returns nil, the semaphore token is **given back** so the
  renderer cannot deadlock, and the frame is reported as `SURFACE_LOST` for the
  caller to skip.
- **GPU error**: surfaced from `commandBuffer.error` rather than ignored.

GPU timing comes from the driver's `GPUStartTime`/`GPUEndTime`, not a CPU-side
estimate.

## 7. Power and scheduling

- App Nap is suppressed with `NSActivityUserInitiatedAllowingIdleSystemSleep`,
  which keeps normal display and idle sleep working. `LatencyCritical`
  (which disables timer coalescing machine-wide) is opt-in only. Titanium does
  not globally disable power management.
- Thread priority uses `pthread_set_qos_class_self_np` on the **calling thread
  only** — no process-wide policy changes, no real-time thread scheduling.
- ProMotion: presentation is paced with
  `presentDrawable:afterMinimumDuration:` when a frame cap is set, and
  `displaySyncEnabled` controls vsync. *(Verified on a 120 Hz variable-refresh
  panel: vsync-locked frames measured at 8.19 ms mean against the 8.33 ms
  interval.)*
