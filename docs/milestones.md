# Titanium — Milestone Plan

Each milestone is required to be **buildable and testable on its own**. A
milestone is not "done" until its tests pass on real hardware and the numbers
are recorded in `PROGRESS.md`.

| # | Milestone | State |
|---|---|---|
| M0 | Feasibility, architecture, repo layout | **done** |
| M1 | Native Metal core + JNI + on-screen validation | **done** — 131 tests passing |
| M2a | `#moj_import` preprocessor, validated on all 85 vanilla shaders | **done** — 20 tests passing |
| M2 | GLSL → MSL translation layer | **2a done**, 2b next |
| M3 | `GpuDevice` implementation + Fabric mixins | next |
| M4 | Capability-gated optimisations | planned |
| M5 | A/B benchmarking vs. the stock renderer | planned |
| M6 | Production hardening and release | planned |

### M1 — done
Device, capabilities, buffers (incl. zero-copy aliasing), textures, samplers,
MSL compilation, pipelines, depth/stencil, render passes with memoryless
attachments, frames in flight, GPU timing, on-disk pipeline archive,
`CAMetalLayer` surface with resize/vsync/ProMotion pacing, App Nap and QoS.
66 native + 48 JVM + 17 on-screen checks.

### M2 — GLSL → MSL translation
Vendor glslang + SPIRV-Cross; resolve `#moj_import`; translate all 93 vanilla
shaders; extract reflection bindings; apply the semantic fixups in
`architecture.md` §3. **Exit criteria:** every vanilla shader translates and
compiles, and a golden-image test proves the depth-range and Y-origin fixups
are correct — not merely that the shaders compile.

### M3 — Backend implementation + Fabric integration
Implement the 57 seam methods in Java over the JNI bridge. Mixins:
`RenderSystem.initRenderer` to construct the Metal device, `Window` to request
`GLFW_NO_API`, `RenderSystem.flipFrame` for presentation. Startup compatibility
scan for GL-calling mods. **Exit criteria:** the main menu renders, then a world
renders, with the fallback path proven to work when Titanium refuses to enable.

### M4 — Capability-gated optimisations
In ascending order of risk:
1. **TBDR pass structure** — memoryless attachments, load/store tuning. Lowest
   risk, already supported by the core.
2. **Unified-memory buffers** — extend the zero-copy path to chunk geometry,
   with explicit lifetime rules. Shared memory removes copies, *not*
   synchronisation; contention must be measured.
3. **Decoupled Retina scaling** — world at one resolution, UI at native.
4. **MetalFX spatial** — configurable internal resolution, correct colour
   handling.
5. **ProMotion pacing** — already implemented; extend to Minecraft's own
   framerate limiter.
6. **MetalFX temporal** — requires real renderer work: jittered projection,
   a motion-vector attachment, and history invalidation on camera cuts,
   teleports and dimension changes. Will not ship, and will not be *called*
   temporal upscaling, until those exist.
7. **Mesh shaders** — only for a workload where the win is measured, with the
   conventional path as default.

### M5 — Measurement
Fixed seeds, fixed camera paths, identical settings, Titanium vs. stock GL.
Report mean/p50/p95/p99 frame times (not just averages), CPU and GPU time,
memory, plus resize, resource-reload, world-transition and long-session
stability. Anything unmeasured stays labelled a hypothesis.

### M6 — Production hardening
Reproducible builds, notarisation-friendly packaging, dependency and licence
documentation, crash diagnostics carrying the capability dump, config
validation, installation instructions.

**No production-readiness claim will be made until M5's acceptance criteria
have actually been tested.**
