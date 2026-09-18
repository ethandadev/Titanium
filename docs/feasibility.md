# Titanium — Feasibility Assessment (Minecraft 1.21.11, Fabric, macOS/Apple Silicon)

**Status:** verified against the real artifacts, not from memory.
**Date:** 2026-09-18

All statements below were checked against the actual 1.21.11 client jar
(SHA-1 `ba2df812c2d12e0219c489c4cd9a5e1f0760f5bd`) and Mojang's official
mappings (SHA-1 `031a68bebf55d824f66d6573d8c752f0e1bf232a`), both downloaded
from `piston-data.mojang.com` and checksum-verified. Evidence commands are in
`tools/verify-mc.sh` so every claim here is reproducible.

---

## 1. Verified target facts

| Fact | Value | How verified |
|---|---|---|
| Version | `1.21.11`, released 2025-12-09 | `1.21.11.json` |
| Required Java | **21** (`java-runtime-delta`) | `javaVersion` in version JSON |
| LWJGL | **3.3.3** (glfw, opengl, stb, freetype…) | `libraries[]` |
| Obfuscation | Obfuscated, with an explicitly **un**obfuscated render API | mappings |
| Window API | GLFW, `GLFW_CLIENT_API = GLFW_OPENGL_API`, GL **3.3 core, forward-compat** | bytecode of `Window` |
| Shaders | 75 `core` + 8 `include` + 10 `post` GLSL files, `#version 330`, std140 UBOs | jar listing |

### The decisive finding

Mojang's 1.21.x "blaze3d" rewrite introduced an explicit, backend-agnostic
graphics abstraction, and **annotated it `@DontObfuscate`** — it survives
obfuscation under its real name, which is Mojang signalling a stable
integration surface:

```
com.mojang.blaze3d.systems.GpuDevice        -> com.mojang.blaze3d.systems.GpuDevice
com.mojang.blaze3d.systems.CommandEncoder   -> com.mojang.blaze3d.systems.CommandEncoder
com.mojang.blaze3d.systems.RenderPass       -> com.mojang.blaze3d.systems.RenderPass
com.mojang.blaze3d.textures.GpuTexture      -> com.mojang.blaze3d.textures.GpuTexture
com.mojang.blaze3d.buffers.GpuBuffer        -> com.mojang.blaze3d.buffers.GpuBuffer
com.mojang.blaze3d.pipeline.RenderPipeline  -> com.mojang.blaze3d.pipeline.RenderPipeline
```

whereas the OpenGL implementation *is* obfuscated (`GlDevice -> fxe`), i.e. it
is an implementation detail, not the contract.

**Interface sizes (the actual work surface):**

- `GpuDevice` — 23 methods (create texture/buffer/sampler/texture-view,
  compile pipeline, capability getters, `close`).
- `CommandEncoder` — 20 methods (render passes, clears, buffer/texture
  writes and copies, map, fence, timer query, **`presentTexture`**).
- `RenderPass` — 14 methods (pipeline, texture binds, uniforms, scissor,
  vertex/index buffers, `draw`, `drawIndexed`, `drawMultipleIndexed`).

That is **57 methods total** to implement a complete backend — not thousands
of scattered GL call sites. This is the single fact that makes the project
tractable.

### Integration points, confirmed by bytecode

1. **Device construction.** `RenderSystem.initRenderer(long, int, boolean,
   ShaderSource, boolean)` disassembles to literally
   `DEVICE = new GlDevice(...)`:
   ```
   0: new #289  // class fxe          (= com.mojang.blaze3d.opengl.GlDevice)
   11: invokespecial fxe."<init>":(JIZLfyy;Z)V
   14: putstatic  DEVICE:Lcom/mojang/blaze3d/systems/GpuDevice;
   ```
   One mixin replaces the whole backend.

2. **GL context creation lives *inside* the GL backend.**
   `glfwMakeContextCurrent` and `GL.createCapabilities` appear **only** in
   `fxe` (`GlDevice`). No other client class creates or uses a GL context.
   Replacing `GpuDevice` therefore removes OpenGL from the process rather
   than leaving a dead context behind.

3. **Presentation.** `RenderSystem.flipFrame(Window, TracyFrameCapture)`
   calls `glfwSwapBuffers`; the backend-side hook is
   `CommandEncoder.presentTexture(GpuTextureView)`.

4. **NSWindow access already exists.** `glfwGetCocoaWindow` is already used by
   `MacosUtil` (`fye`), and LWJGL 3.3.3 exposes `GLFWNativeCocoa`. Titanium
   needs no new mechanism to reach the `NSWindow` to attach a `CAMetalLayer`.

5. **Pipeline state is fully described in Java.** `RenderPipeline` carries
   vertex/fragment shader locations, `ShaderDefines`, sampler *names*, uniform
   block descriptions, depth test function, polygon mode, cull flag, blend
   function, colour/alpha/depth write masks, `VertexFormat`, primitive mode,
   and depth bias. Every field except one (see §3) maps onto
   `MTLRenderPipelineDescriptor` + `MTLDepthStencilState` + encoder state.

---

## 2. Host capability verification (this machine)

Checked with `system_profiler`, `xcrun`, and a live `MTLDevice` probe
(`native/tests/ti_selftest`):

| Item | Value |
|---|---|
| macOS | 26.6.2 (build 25G82) |
| GPU | Apple M3 Max, 30 cores, **Metal 4**, Apple family 9 |
| Xcode / SDK | 26.0.1 / MacOSX26.0 |
| Metal compiler | `metal` 32023.830, target `air64-apple-darwin25.6.0` |
| Display | Liquid Retina XDR, 3456×2234 |

Every Metal feature Titanium uses is gated on a runtime query
(`ti_probe`/`ti_device_caps`) rather than on an assumed OS or chip version.

---

## 3. Things that are **not** straightforwardly feasible

Honest list. Each has a stated alternative.

### 3.1 GLSL is unavoidable — Metal cannot consume it
Minecraft ships 93 GLSL 330 files and resource packs may replace any of them,
so hand-written MSL alone cannot be correct in general.

**Approach:** compile GLSL → SPIR-V → MSL with glslang + SPIRV-Cross, linked
*into the native library*, with the resulting MSL and `MTLLibrary` binaries
cached on disk keyed by a hash of (source + defines + backend version).

This is **source translation at load time, not a runtime API translation
layer**: no Vulkan driver, no `VkDevice`, no MoltenVK. At runtime the process
talks to Metal directly. SPIRV-Cross reflection also supplies the
name → index mapping needed for `RenderPass.bindTexture(String, …)` and
`setUniform(String, …)`, which Metal expresses as numeric binding slots.

### 3.2 `LogicOp` has no Metal equivalent — hard gap
`RenderPipeline.getColorLogic()` exposes OpenGL logic-op blending
(`GL_OR_REVERSE` etc.). **Metal has no fixed-function logic ops at all.**

**Alternative:** pipelines whose logic op is not `NONE` are rendered through a
fragment-shader emulation path that reads the current colour via programmable
blending (available on Apple GPUs — `supports_programmable_blending`) and
applies the bitwise op. Where the target is not readable, Titanium refuses the
pipeline and reports it rather than rendering something subtly wrong.

### 3.3 `Depth24Unorm_Stencil8` does not exist on Apple silicon
Apple GPUs report `depth24Stencil8PixelFormatSupported == false`.

**Alternative:** map it to `Depth32Float_Stencil8`. Higher precision, 2 bytes
more per pixel. Detected at runtime via `supports_depth24_stencil8`.

### 3.4 Shader packs (Iris/OptiFine) are out of scope, permanently
They inject GLSL *and* call GL directly. With `GLFW_CLIENT_API = GLFW_NO_API`
there is no GL context to call into. Titanium will **detect these mods at
startup and refuse to enable**, falling back to the vanilla GL renderer,
rather than crashing halfway through world load.

### 3.5 Any mod making direct LWJGL GL calls will crash
Same root cause. Mitigation is the same: a compatibility scan at startup, an
explicit allow/deny list, and a documented boundary (`docs/compatibility.md`).

### 3.6 Mesh shaders: supported, but the workload has to justify them
`MTLDevice.supportsFamily(.apple7+)` gates object/mesh shaders, and the M3 Max
here qualifies. But Minecraft's chunk geometry is CPU-built into vertex
buffers; a mesh-shader path only pays off if chunk meshing moves GPU-side,
which is a much larger change than a backend swap.

**Plan:** implement mesh shaders for a *bounded* workload where the win is
measurable (GPU-side chunk quad expansion / cluster culling), keep the
conventional vertex path as the default, and gate on measured benefit rather
than on availability. Not claimed as working until benchmarked.

### 3.7 MetalFX temporal upscaling needs data Minecraft does not produce
Temporal upscaling requires per-pixel motion vectors, a jittered projection
matrix, depth, and history invalidation. Minecraft renders **no motion
vectors** and does not jitter its projection.

**Plan:** this is a genuine renderer change, not a wrapper — inject jitter into
the projection matrix, add a motion-vector attachment fed by previous-frame
model-view-projection per draw, and handle camera cuts/teleports/dimension
changes as history resets. Until that is implemented and validated, Titanium
will expose **spatial** upscaling only, and will not label anything else
"temporal".

---

## 4. Verdict

**Feasible**, with a genuinely favourable architecture: 1.21.11 already has the
backend seam this project needs, the seam is explicitly stability-marked, and
the OpenGL context is confined to the component being replaced.

The hard parts are not the Metal API — they are (a) GLSL→MSL translation
fidelity, (b) the long tail of rendering-semantics differences (logic ops,
depth formats, coordinate conventions), and (c) the fact that temporal
upscaling and mesh shaders require real renderer work rather than
configuration.

Scope is therefore staged so that a working, measurable Metal path exists
before any advanced feature is attempted. See `docs/milestones.md`.
