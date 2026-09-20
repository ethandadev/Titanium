# Titanium — Progress Log

Persistent record of what is done, what is broken, and what is next.
Updated as work proceeds. **Nothing is marked done unless it was built and tested.**

---

## Milestone 0 — Feasibility & architecture — **DONE**

- Downloaded and SHA-1 verified the real 1.21.11 client jar and Mojang
  official mappings from `piston-data.mojang.com`.
- Established the backend seam by disassembling the actual bytecode
  (not from memory): `GpuDevice` (23 methods), `CommandEncoder` (20),
  `RenderPass` (14) — all `@DontObfuscate`.
- Confirmed the injection point: `RenderSystem.initRenderer` literally does
  `DEVICE = new GlDevice(...)`.
- Confirmed GL context creation is confined to `GlDevice` (`fxe`), so
  replacing the device removes OpenGL rather than leaving a dead context.
- Confirmed `glfwGetCocoaWindow` is already used by `MacosUtil` (`fye`).
- Documented in `docs/feasibility.md`, reproducible via `tools/verify-mc.sh`.

**Known gaps recorded:** `LogicOp` has no Metal equivalent;
`Depth24Unorm_Stencil8` unsupported on Apple silicon; shader packs are
permanently out of scope; MetalFX temporal needs motion vectors Minecraft
does not currently produce.

## Milestone 1 — Native Metal core — **DONE (66/66 tests passing)**

`native/` builds a real `libtitanium.dylib` against the macOS SDK with no
third-party dependencies.

Implemented and verified on Apple M3 Max / macOS 26.6.2:

| Area | Status |
|---|---|
| Device creation, capability detection | done, verified |
| Buffers (shared / private / no-copy aliasing) | done, verified |
| Textures, uploads, readback, mipmaps | done, verified |
| Samplers | done, verified |
| MSL compilation + `metallib` loading | done, verified |
| Render pipelines, vertex descriptors, blending | done, verified |
| Depth/stencil state | done, verified |
| `CAMetalLayer` surface, resize, vsync, ProMotion pacing | done, verified on screen |
| Frames in flight (semaphore-paced), GPU timing | done, verified |
| Render passes incl. memoryless (TBDR) attachments | done, verified |
| On-disk pipeline binary archive | done, verified |
| App Nap activity + thread QoS | done, verified |

### Bugs found and fixed during M1
1. **MSL/C++ struct layout mismatch.** `float3` in MSL is 16-byte aligned, so
   a trailing `float4` landed at offset 32 in the shader but 16 in C++ — the
   fragment shader silently read zeros and two tests rendered nothing. Fixed
   by using three scalar floats; `static_assert`s now pin the layout so it
   cannot regress. This is the same class of bug the future GLSL→MSL layer
   must handle systematically for std140 blocks.
2. `NSWindow` referenced in the internal header without AppKit — replaced with
   a forward declaration to keep AppKit out of most translation units.
3. `MTLGPUFamilyMetal3` / `MTLLanguageVersion3_0` are macOS 13 symbols; used
   numeric family constants so the deployment target can stay at macOS 12.

### Measured on this machine (real numbers, offscreen microbenchmark only)
240 frames × 200 indexed draws at 512×512:
`mean 0.111 ms, p50 0.121 ms, p99 0.359 ms, max 0.579 ms` CPU submit time;
last-frame GPU time 0.060 ms (driver timestamps, not a CPU estimate).

**These are native-harness numbers. They say nothing about Minecraft frame
rates and must not be presented as such.**

---

## Milestone 1b — JNI bridge + Java loader — **DONE (48/48 tests passing)**

- `native/src/jni/ti_jni.mm`: 62 exported JNI entry points; `libtitanium.dylib`
  links Metal/QuartzCore/AppKit with **MetalFX weak-linked** so it still loads
  on macOS 12 where MetalFX is absent.
- `TitaniumNative` (raw bindings), `TiCaps` (parsed capabilities),
  `NativeLoader` (platform gate + jar extraction keyed by SHA-256).
- **Interop decision recorded:** JNI, not FFM. 1.21.11 declares
  `javaVersion.majorVersion = 21`, where `java.lang.foreign` is still a
  *preview* API — an FFM mod would need `--enable-preview` on the vanilla
  launcher JRE. The C ABI is kept FFM-shaped so a Java 22+ binding can be
  added later without touching native code.
- Zero-copy path proven: `nBufferContents` hands Java a direct `ByteBuffer`
  aliasing GPU-visible memory; the JVM writes vertices with no staging copy.
- **Verified on Minecraft's own bundled runtime** (OpenJDK 21.0.3,
  `java-runtime-delta`), not only on the system JDK 25: 48/48 passing.

## Milestone 1c — On-screen validation — **DONE (17/17 tests passing)**

`native/tests/ti_windowdemo.mm` creates a real `NSWindow` — the same object
`glfwGetCocoaWindow()` returns — attaches a `CAMetalLayer` through the public
API, and drives genuinely presented frames. Verified on the M3 Max / Liquid
Retina XDR:

- Retina scale applied correctly: **1800x1120 drawable for a 900x560 pt window**.
- Display detected as **120 Hz with variable refresh** (ProMotion).
- **150 frames presented, 0 drawable timeouts, 0 errors.**
- Live resize honoured: drawable went 1800x1120 -> 1480x880 mid-run.
- vsync genuinely paces the loop: **mean 8.19 ms, p50 8.29 ms, p99 8.45 ms**,
  which is the 120 Hz frame interval (8.33 ms) — the loop is not free-running.
- vsync toggle, ProMotion frame cap, and display-change handling all accepted.

## Milestone 2a — GLSL preprocessor — **DONE (20/20 tests passing)**

`GlslPreprocessor` resolves `#moj_import` into one translation unit (exactly
one leading `#version`, `#line` directives for diagnostics) and derives a
stable, length-prefixed cache key. Validated against all 85 vanilla
entry-point shaders (67 use imports). Minecraft's assets are never committed;
the test reports SKIPPED, not passed, when the corpus is absent.

Bugs the corpus caught: dedup ran before the cycle check (a real cycle
produced a half-inlined file instead of an error), and the dedup marker
contained the directive text. Vanilla quirk found: `rendertype_end_portal.vsh`
imports `projection.glsl` twice.

**Scope correction (found during M2b):** this is *not* on the in-game path.
`ShaderManager` resolves imports itself and `GlDevice` only calls Mojang's
static `GlslPreprocessor.injectDefines`; Titanium's device will do the same.
M2a remains the offline path for corpus tests and cache keys.

*(Recording note: this section was reported as written at the end of the
previous session but the edit had silently failed to apply. Doc edits are now
asserted.)*

## Milestone 2b — GLSL -> MSL translation — **DONE (45 golden + 100 corpus compiles)**

**Dependency decision (made on "continue", recorded here):** glslang and
SPIRV-Cross are fetched by `tools/fetch-deps.sh` at `vulkan-sdk-1.4.357.0`,
verified by **git commit hash** (GitHub tarballs are not byte-stable), into
gitignored `native/third_party/`, built by `make deps` as static archives with
hidden visibility. Zero third-party symbols leak from the dylib. Offline after
first fetch; nothing installed system-wide. Licences in `docs/third-party.md`,
including glslang's Bison-generated parser (GPL-3.0 *with the Bison
exception*, so copyleft does not extend to Titanium).

`ti_translate_glsl()` (C ABI + JNI) links vertex+fragment, applies the depth
and Y fixups, assigns collision-free Metal slots, and reports reflection.

**Golden tests render with translated shaders and assert GL's pixels**:
depth range (0.50/0.25/0.75 measured exactly), framebuffer origin,
render-then-sample, `gl_FragCoord`, winding + `gl_FrontFacing` + culling,
`gl_VertexID` with base vertex, std140 vec3+float packing, varying order,
unused inputs, MSL-reserved identifiers, error reporting. **45/45.**

**Vanilla corpus:** all **50 pipelines** (43 linked pairs) translate *and*
compile with Metal, with only the required define and with all 7 macros on:
100/100, run on Minecraft's own Java 21.

### Bugs found this milestone
1. **Varyings matched by declaration order**, not name: glslang's `mapIO()`
   does not relink by name for the OpenGL client. Golden test 9 failed until
   fragment inputs were re-pointed by name.
2. **std140 block size under-reported** (44 vs 48): SPIRV-Cross's declared
   size omits std140's round-up to 16.
3. **Too strict on unused inputs**: rejected vanilla `text_background`, which
   GL links fine. Only *used* unmatched inputs are errors now.
4. **`sampler` as a GLSL identifier** (vanilla `terrain.fsh`) broke the Metal
   compile. Renamed after reflection so bind names are unaffected.
5. **Latent: MSL 3.0 on macOS 12.** The core always compiled with
   `MTLLanguageVersion3_0`, absent on the stated deployment target.
6. **Makefile had no header dependencies**; an ABI change left stale objects.
7. **README said `verify-mc.sh` extracted the corpus; it didn't.** Fixed.

### Earlier claims of mine that the tests disproved (corrected in architecture.md)
- That GL's `gl_VertexID` excludes the base vertex. It includes it, as Metal's
  does; test 7 measured 4,5,6.
- That `gl_FragCoord` needs a height-based fix. It doesn't once render targets
  keep GL's memory layout; test 5 confirms.

### Known open gap
`flat` varyings: GL's provoking vertex is the last, Metal's the first. Only
vanilla `rendertype_leash` uses `flat`. Fix planned in M3 (index rotation).

## Milestone 3a — Minecraft renders on Metal (title screen) — **DONE, verified in-game**

The full backend exists: `MetalDevice` / `MetalCommandEncoder` /
`MetalRenderPass` plus buffer, texture, view, sampler, fence, timer-query and
pipeline types — all 57 seam methods — over JNI, with three mixins
(`Window` hints/vsync/resize, `RenderSystem.initRenderer`, `flipFrame`).
Built with Loom 1.17.21 + Gradle 9.6.1 against Mojang mappings; run on
**Minecraft's own Java 21 runtime**, not the Gradle JDK.

**Result:** Minecraft 1.21.11 boots to the title screen with **no OpenGL
context in the process**, renders it on Metal, takes a screenshot through the
game's own `Screenshot` path (exercising `copyTextureToBuffer`, the fenced
callback queue and a read-mapped buffer), and quits cleanly.

**A/B against stock OpenGL** (same machine, same settings, `-Ptitanium=false`):
- Every button region — sprites, text, blending — is **bit-identical**: 100.00%
  of pixels equal, max difference 0 (≈200k pixels compared).
- Whole frame 59% identical; an 8x-amplified diff shows differences only on the
  time-rotated panorama's texture edges and the random splash text, i.e. no
  systematic error (gamma, flip, channel order or blend math would light up
  the whole frame).
- Frame times under the title screen's menu cap (vsync on) — **pacing, not
  throughput; one run each; not a performance claim**:
  Metal mean 18.15 ms, p95 20.16, p99 20.60, max 21.0;
  OpenGL mean 18.18 ms, p95 22.45, p99 23.32, max 30.6.

Harness: `./gradlew runClient -Pselfcheck=<label> [-Ptitanium=false]`
(`SelfCheck.java`) measures 600 frames after 240 warm-up, screenshots, exits.

### Bugs found by running the real game
1. **Metal aborted the process** on a 16x16 texture with 6 mip levels (GL
   silently makes the extra level 0x0). Metal's framework asserts kill the
   process *even with validation off*, so the native layer now pre-validates
   mip counts, view ranges and every copy region, reproducing GL's leniency
   (0x0 levels and regions are no-ops) and returning errors otherwise. Six
   regression checks added.
2. **Mojang logo missing on the loading screen.** GL caches compiled shader
   *modules* by (id, stage, defines); startup pipelines reuse shaders the GUI
   preload compiled, before `ShaderManager` can supply source. Titanium cached
   only whole pipelines, looked the source up afresh and got null. Found by the
   A/B (GL logs no such error). Now mirrors GL's per-shader cache.
3. **Sampler `maxLod 0` meant "unbounded"** in the M1 native code; Minecraft
   uses 0 to pin mip 0. Fixed with a regression test.
4. **Self-check waited for `TitleScreen`**, but a fresh game dir shows the
   accessibility onboarding first. Now triggers on "loading finished".
5. **Mid-frame uploads would have overtaken the frame** (M1's immediate-submit
   uploads). Replaced by frame-ordered transfers; a test proves an upload lands
   between the passes around it.

### Verified facts that changed the design
- Vanilla **never uses `LogicOp`** (no `withColorLogic` callers; text inversion
  uses `BlendFunction.INVERT`). The one hard Metal gap is third-party only.
- Every write-mapped buffer comes from `MappableRingBuffer`, which fences
  before reuse; GL's persistent-mapping path is already unsynchronised. So a
  direct unified-memory pointer is correct *given exact fences*.
- Only `RenderSystem` touches GL outside the backend (`glfwSwapBuffers`), plus
  `Window`'s `glfwSwapInterval`; both are intercepted (a GLFW error during boot
  would hit `bootCrash`).

### Not yet exercised (honest scope of "verified")
The title screen covers GUI, text, cube-map panorama, blur post-processing and
presentation. **It does not exercise** world geometry, entities, particles,
fog, clouds (texel buffers), translucency sorting, the lightmap in the vertex
stage, or resize/fullscreen/resource-reload. Those need an in-world run.

## Milestone 3b — In-world on Metal, A/B'd against OpenGL — **DONE**

Deterministic scene: a world made with Mojang's own "DEBUG world" recipe
(seed `"test1".hashCode()`), `/tick freeze`, noon, clear weather, absolute
camera `(0.5, 80, -6.5)` yaw 135 pitch 20, GUI hidden, render distance 16,
1708x960, M3 Max, macOS 26.6.2, Minecraft's own Java 21. Measurement starts
only when all sections are built **and** the count has been stable for 240
frames; a run whose count changes during measurement is marked UNSTABLE.

**Image parity (Metal vs OpenGL, same repetition):** 99.96% of pixels
identical, 99.99% within ±2, **0.00% differ by more than 32**, mean |diff|
0.001–0.002 — the same order as each backend's own run-to-run noise
(99.98–99.99% identical). Terrain, cutout leaves, translucent water, sky, fog,
clouds (texel buffers), entities, and the vertex-stage lightmap all render.

**Performance, vsync off, 3 alternating repetitions each, all runs stable
(776–786 sections):**

| | frame mean | p99 | GPU time (Minecraft TimerQuery) |
|---|---|---|---|
| OpenGL (stock) | 5.28 / 5.57 / 5.38 ms | 10.2 / 10.5 / 10.3 ms | 3.26 / 3.41 / 3.20 ms |
| Metal (Titanium) | 1.33 / 1.22 / 1.30 ms | 2.60 / 2.07 / 2.18 ms | 1.42 / 1.33 / 1.43 ms |

What this does and does not show:
- It is **one scene**, and a poor one: the fixed camera sits inside a tree
  canopy, so leaves dominate. Valid for this scene; **not** representative of
  gameplay. A second "vista" camera is next.
- Frame-time is not a like-for-like "fps" comparison. With vsync off, Titanium
  commits every frame but presents only when a drawable is free (≤120/s here,
  see architecture 7.1); stock GL's swap hands every frame to the compositor.
  Part of the frame-time gap is that presentation difference.
- The GPU-time column is the cleaner signal but uses two instruments:
  `GL_TIME_ELAPSED` on OpenGL, command-buffer timestamps on Metal (Minecraft's
  own TimerQuery on both).
- Memory is not compared: Metal reports ~240–275 MB allocated
  (`currentAllocatedSize`); stock GL exposes no equivalent here.

**A discarded run, recorded because it matters:** the first A/B used a
*relative* teleport. The world saves the player, so each run started 12 blocks
higher and the two backends never rendered the same view (y=184 vs y=196).
The image diff (9.5% identical) exposed it; those numbers were thrown away
(`bench/results/INVALID-...`). The absolute-position harness fixed it.

### Lifecycle stress — **all 8 steps pass, zero errors**
`./gradlew runClient -Pselfcheck=stress -Pworld=titanium-bench -Pstress`:
baseline → resize to 960x540 pt (target 1920x1080 on Retina) → restore →
fullscreen on (1920x1200) → off → **full resource reload** (every pipeline
recompiled; identical image) → Save-and-Quit to title → rejoin (re-settled at
786 sections) → clean exit. Every step screenshotted and checked.

### Fixed this milestone
- **Uncapped runs were display-locked at 120 fps** (a windowed CAMetalLayer
  withholds drawables at the refresh rate even with `displaySyncEnabled = NO`).
  With vsync off, frames the display cannot show are now committed unpresented,
  as GL drops them at swap interval 0. Demo: 4,665 fps rendered, one present
  per refresh, 0 drawable timeouts.
- **`flat` varyings / provoking vertex (the leash):** fragment inputs declared
  `flat` are now reported by the translator, and such draws are reordered so
  GL's last vertex comes first (strips expanded). Golden test 12 shows the bug
  (red/green) and the fix (blue/yellow) in pixels; 8 unit tests cover the
  reordering. Triangle fans share the same expander.
- Harness bugs (not Titanium): re-entrant `onFrame` during world creation
  (StackOverflowError), relative teleport drift, and a Save-and-Quit that
  skipped `level.disconnect()` and waited forever for the server.

### Open
- Pipeline-archive serialization failed intermittently at shutdown
  ("expecting 'fragment' stage in pipeline no. 10"), twice in world runs, not
  reproduced since. Non-fatal (the next launch recompiles). The failure now
  logs every archive entry in order, so the next occurrence names the pipeline.
  A write-mask-0 hypothesis was tested and disproved.

### Vista A/B (representative open scene) — 3 alternating reps each, all stable

Camera `(0.5, 120, -6.5)` yaw 135 pitch 25 over hills, forest and a river;
otherwise identical settings.

| | frame mean | p99 | GPU (TimerQuery) | sections |
|---|---|---|---|---|
| OpenGL | 6.02 / 6.15 / 6.21 ms | 10.9 / 11.1 / 11.6 ms | 3.48 / 3.58 / 3.56 ms | 865–905 |
| Metal  | 1.53 / 1.53 / 1.43 ms | 3.01 / 2.55 / 2.56 ms | 1.92 / 1.95 / 1.92 ms | 874–904 |

Image parity: Metal vs GL 99.83–99.85% identical (one rep 96.50% identical but
99.63% within ±2), ≤0.02% of pixels off by >32 — *smaller* than GL's own
run-to-run variation (GL r1 vs r3: 99.65% identical, 0.04% >32). Section
counts vary ±2% run-to-run on both backends (edge-of-render-distance chunks),
so workloads are close but not identical. Same caveats as above apply:
presentation differs with vsync off; GPU timers are different instruments.

## Milestone 6a — Release jar verified in a production install — **DONE**

`./gradlew build` produces `titanium-0.2.0.jar` (1.9 MB; the 5.7 MB dylib
compressed inside, plus the glslang and SPIRV-Cross licence texts under
`META-INF/licenses/`) and now **runs every Java test harness** (79 checks) on
Minecraft's own Java 21. Gradle 9 had been failing the build because the
harnesses are `main()`-based, not JUnit.

`tools/prod-launch.py` assembles a genuine Fabric Loader 0.19.5 + 1.21.11
install from Mojang and Fabric metadata in a private directory (never touching
the user's launcher) and runs the release jar there — intermediary names,
no `titanium.native.path`:

| Scenario | Result |
|---|---|
| Normal | Metal; title screen renders; screenshot; clean exit |
| `-Dtitanium.enabled=false` | clean fallback to stock OpenGL |
| incompatible mod present (stub declaring id `sodium`) | Titanium detects it, logs why, stays off; stock OpenGL renders |

Verified details:
- **No refmap is needed:** Loom rewrote the mixin targets to intermediary
  names in the bytecode (`Window` → `class_1041`, `updateVsync` →
  `method_4497`, …). The mixin config's stale `refmap` entry was removed so
  users don't see a "could not read reference map" warning.
- **The dylib provably comes from the jar:** the extraction directory is named
  by the dylib's SHA-256; `d31719adb85aa46e` matches the jar entry.

## Milestone 4a — Config + TBDR deferred clears — **DONE; result: no measurable gain, default OFF**

`config/titanium.json`, strictly validated: unknown keys, wrong types and
out-of-range values are reported by name and replaced by defaults; the file is
rewritten atomically with every key present. `-Dtitanium.<key>=` overrides a
setting for one launch (used by the A/B scripts). `enabled=false` in the file
is a third off switch, alongside the JVM flag and automatic detection.

**Deferred clears** fold full-texture clears into the next render pass's
`loadAction = Clear` instead of a standalone clear pass (which on TBDR stores
the whole attachment and has the next pass load it back). Every other
observation of the texture materialises the clear first, preserving GL order.

Measured (vista, Metal off vs on, 3 alternating reps):

| | frame mean | GPU mean | sections |
|---|---|---|---|
| off | 1.543 / 1.541 / 1.529 ms | 1.948 / 1.899 / 1.948 ms | 891 / 867 / 890 |
| on  | 1.524 / 1.486 / 1.510 ms | 2.010 / 2.069 / 1.978 ms | 912 / 904 / 895 |

**Not demonstrably beneficial, so off by default.** Frame time moved ~1.5%
(noise level); GPU time rose, but tracked section count across all six runs,
and the "on" runs loaded more sections, so the scene variance confounds it.
The premise was weaker than assumed: the saved ~13 MB/frame is ~0.03 ms at an
M3 Max's bandwidth; and only ~4.4k clears folded while ~6k had to be
materialised anyway. Rendering is unaffected when enabled (≤0.01% of pixels
off by >32). It may matter on lower-bandwidth chips — **untested hypothesis**.

Benchmark weakness exposed: section counts still vary ±3% between runs, which
is now the dominant confound for small effects. Effects smaller than ~5% of
GPU time cannot be resolved by this harness yet.

## Milestone 4b — Decoupled world resolution + MetalFX spatial — **DONE; off by default**

The world block of `GameRenderer.render` renders into a `worldScale`-sized
target and is upscaled into the main target before the GUI draws at full
resolution (architecture 7.2). MetalFX spatial (perceptual colour mode) or
bilinear; MetalFX falls back to bilinear, with one log line, where unsupported.
Verified: GUI text pixel-crisp while the world is upscaled; the full lifecycle
stress (resize, fullscreen, resource reload, rejoin) passes with scaling on;
native test proves both upscalers keep every quadrant in place (no flip).

Measured (vista, uncapped; MetalFX rows are 3 alternating reps vs native,
bilinear rows are **single runs — indicative only**):

| | frame mean | GPU (TimerQuery) | memory | PSNR vs native |
|---|---|---|---|---|
| 1708x960 native | 1.53 ms | 1.94 ms | 277 MB | — |
| 1708x960 0.67 MetalFX | 1.52 ms | 2.01 ms | 290 MB | 27.96 dB |
| 1708x960 0.67 bilinear | 1.38 ms | 1.70 ms | 282 MB | 29.73 dB |
| 3200x2000 native | 2.48 ms | 2.85 ms | 397 MB | — |
| 3200x2000 0.67 MetalFX | 2.31 ms (−6.6%) | 3.08 ms | 445 MB | 28.13 dB |
| 3200x2000 0.67 bilinear | 1.86 ms (−25%) | 2.18 ms | 421 MB | 29.81 dB |

What this shows:
- At 1708x960 on an M3 Max, cutting world pixels by 55% buys nothing with
  MetalFX: the frame is not fill-bound there, and the MetalFX pass costs more
  than the saved fill.
- At 3200x2000 it helps: −6.6% frame time with MetalFX, consistent across reps
  (ranges do not overlap), for +48 MB. MetalFX's own pass costs ≈0.45 ms/frame
  at that output size, which eats most of the saving; bilinear keeps it.
- **Quality is a genuine trade-off, not a win for either.** Bilinear scores
  higher PSNR (29.7–29.8 vs 28.0–28.1 dB) because blur minimises squared
  error; MetalFX looks sharper (crops inspected) but its sharpening moves
  pixel values on Minecraft's hard-edged textures. PSNR is a fidelity metric,
  not a perceptual one.
- Decision: off by default; when enabled, `upscaler` defaults to MetalFX
  (sharpness is the reason to upscale rather than just lower resolution), and
  the config documents that bilinear is faster.
- The per-command-buffer GPU timer *rises* with MetalFX even where frame time
  falls — consistent with overlapping GPU work; this timer is not a
  throughput measure and is reported only as supporting data.

Also this milestone: config schema versioning with an explicit migration
(v1 files carried the old `deferredClears=true` default; verified migrated),
`-D` overrides verified not to leak into the saved file.

## Soak test — 20 minutes, **no leak found, zero errors**

`-Psoak=20`: time, weather and entities running; the camera travels 48 blocks
(3 chunks) east every 3 s through freshly generated terrain (3,312 blocks
total), so chunk buffers are created and destroyed continuously. Logged every
minute:

- Metal allocated memory 238–303 MB, tracking loaded chunks, **no trend**
  (minute 20: 260 MB; minute 1: 280 MB).
- Live buffers track the chunk count (1,655–4,051), no trend.
- Live views (5) and samplers (33): constant.
- Live textures 716 → 733, plateaued from minute 15: Minecraft lazily loading
  assets on first use (e.g. mobs first met in new biomes). Titanium creates no
  textures of its own in this configuration.
- Frame times after minute 1 reflect Minecraft's **inactivity limiter**
  (30 fps after a minute without input), not Titanium — not a performance
  result.

Not covered: sessions of hours; multiple displays.

## Shader caching — measured, then built (see architecture "Caching")
- Startup shader cost is dominated by translation (~131 ms/launch), not MSL
  compilation (~4 ms) or pipeline creation (~3 ms). A translated-MSL disk
  cache now takes warm-launch translation to 0 ms (96/96 hits), with frames
  pixel-identical to fresh translation at noise level.
- **Correction:** the architecture doc had claimed this cache existed before it
  did. Fixed in the doc.
- The pipeline archive grew unboundedly (746 KB → 2.7 MB) by merging sessions;
  now a fresh archive per session (bounded, ~614 KB). It gives no measurable
  gain on this machine. The intermittent serialization failure is now a single
  WARN that keeps the previous file; two hypotheses (write-mask-0 pipelines,
  teardown order) were tested and ruled out; root cause still unknown.

## Website refresh — **DONE (live)**
- `web/index.html` now reports the measured, caveated A/B results (canopy and
  vista, one machine) and the verified correctness figures, instead of "no
  performance claims yet". Redeployed and verified: HTTPS 200, certificate
  valid, new content present on the live page.

## M5 breadth — CPU, memory, weather, and a geometry-heavy scene — **DONE**

New measurement instruments (architecture §8), all verified by tests:
- **Per-pass GPU stage timing** via Metal stage-boundary counters: vertex and
  fragment spans per render pass, by Minecraft's own pass labels. Native test
  [10] renders a synthetic vertex-bound and fragment-bound pass and checks each
  lands in the right stage and inside the command buffer's GPU time.
- **Blocked-on-GPU accounting**: time waiting for a frame slot, a fence, or a
  drawable. Native test [11] checks a free slot is not counted, a real wait is
  counted with its duration, and an already-complete serial is not.
- **Backend-neutral CPU/memory** in the report: process CPU per frame and as
  cores, render-thread CPU per frame, and RSS — identical instruments on GL
  and Metal. (The first cut reported only cores over a ~1 s window, which was
  too noisy to compare; per-frame CPU replaced it.)
- **Scene controls**: weather (clear/rain/thunder) with the world stepped a
  fixed number of ticks to reach the target level, the weather animation phase
  pinned, render distance (also broadcast to the integrated server), and a
  settle gate that waits for the loaded-chunk count to hold for 3 s.

Three bugs in the harness found by these instruments, all fixed:
1. "Clear" scenes were not clear — weather persists in the saved world and a
   frozen world never ramps it down, so runs after a rain run still had rain.
2. The rain scene was measured **while the world was still ticking** (texture
   animation passes gave it away); settling now waits for the step to finish.
3. Render distance 32 never loaded more chunks: the server sends what the
   client *requested* in ClientInformation, which needs `broadcastOptions()`.

### Rain (vista, 1708x960, 3 alternating reps)
| | frame mean | p99 | GPU (TimerQuery) |
|---|---|---|---|
| OpenGL | 6.27–6.72 ms | 11.2–11.8 | 3.58–3.98 |
| Metal | 1.67–1.80 ms | 2.5–4.5 | 2.20–2.22 |

Rain renders correctly (streaks, fog tint, splash particles). Pixel parity in
this scene is limited by the animation phase: the one rep pair that landed on
the same phase scored 49.2 dB (MAE 0.06), while GL-vs-GL scored 30.9 dB.

### Render distance 32 (vista, 2,962 sections, 3 alternating reps)
| | frame mean | p99 | GPU | render-thread CPU/frame | process CPU/frame |
|---|---|---|---|---|---|
| OpenGL | 12.07–12.23 ms | 15.7–16.5 | 9.20–9.34 | 10.67–10.84 | 12.8–13.1 |
| Metal | 4.40–4.53 ms | 6.1–6.5 | 3.86–3.91 | 4.26–4.38 | 9.0–10.4 |

Parity 53.4–54.3 dB against GL's own run-to-run 54.2 dB. The gap here is
almost entirely **CPU on the render thread**: GL spends 10.7 ms/frame there,
Titanium 4.3 ms.

## Mesh shaders — **evaluated, not built** (architecture §9)

Measured with the new instruments rather than argued from the feature list:
the frame rate is set by the render thread, and more so as geometry grows — at
32 chunks the CPU is busy 97% of the frame and waits on the GPU 0.4%, so
cutting GPU geometry cost cannot raise the frame rate there at all. At 16
chunks the ceiling for *any* GPU-side saving is the waiting time: ~25% (vista)
and ~12% (canopy). A backend-only mesh path would also have to re-express
Minecraft's terrain vertex shader as a mesh function (SPIRV-Cross cannot emit
mesh shaders from vertex GLSL) and build meshlet data on the render thread —
the resource that is already the bottleneck. Decision recorded with the
conditions under which it should be revisited.

## Draw submission — batched chunk draws — **DONE** (architecture §10)

Found by profiling the render thread at 32 chunks, where it is the bottleneck:
6,050 draws/frame cost 497 ns each. Ruled out JNI (3.3 ns/call measured) and
the Metal calls themselves (74 ns/draw back to back in a raw-Metal
microbenchmark) — the cost was **interleaving**: Minecraft's per-section work
between per-draw Metal calls left every buffer object cache-cold (233 ns/draw
in the same benchmark with 512 KB of traffic between draws).

`ti_pass_draw_indexed_stream` now encodes a whole layer's draws in one native
call, skipping repeated binds and using `setVertexBufferOffset` for
offset-only changes.

- **Pixel-identical**, proven in one run: three consecutive frames rendered
  batched / per-draw / batched compare at 0 differing pixels (and the batched
  pair matched, so no animation tick intervened). Native test [12] also
  requires stream and individual calls to be byte-identical and malformed
  streams to be rejected.
- 32 chunks: frame 4.39–4.64 -> 3.86–4.24 ms (**-8 to -14%**, 3 alternating
  reps, ranges do not overlap), render-thread CPU 4.27–4.52 -> 3.72–4.12 ms,
  GPU unchanged.
- 16 chunks (default): frame unchanged — the frame is GPU-paced there, so the
  saved CPU has nowhere to show. Render-thread mean 1.14 -> 1.03 ms, but the
  per-rep ranges overlap: a direction, not a result.
- The stream's scratch array lives on the command encoder: per pass it grew to
  ~1 MB **every frame** (passes are per frame), which cost ~0.4 ms/frame on
  the render thread until it was moved.
- Emulated primitives (fans, flat provoking vertex) keep the per-draw path;
  `-Dtitanium.batchDraws=false` restores it for measurement.

## Benchmark validity — what "settled" has to mean

Every performance number depends on both backends measuring the *same scene*,
and at 32 chunks that turned out to be much harder than at 16. Four separate
failures showed up, each caught by comparing section counts between runs, and
each fixed before the numbers below were taken:

1. **240 stable frames is not a settle criterion.** Uncapped, that is under
   half a second, and a lull in section-mesh building satisfies it. Two runs
   measured a half-built world (1,173 of ~2,950 sections; another went
   588 -> 903 *during* the window). Counts must now hold for 3 s of wall time.
2. **Quiescence cannot tell "loaded" from "the server paused".** Chunk
   delivery at 32 chunks stalls for seconds at a time: runs settled anywhere
   between 2,892 and 3,725 chunks — different scenes with different frame
   times. Benchmark scenes now state the count they must reach
   (`-PexpectChunks=3725`), and a run that times out below it is logged and
   marked `NOT_LOADED`.
3. **The visible set grows asynchronously.** Minecraft's occlusion graph
   expands on its own schedule, so a fast backend can go quiet at a fraction
   of the final set (seen: 1,147 of 2,950). Settling now requires at least 95%
   of the largest section count seen while settling.
4. **And it can collapse.** One run's visible set fell from 2,969 to 846
   sections and never recovered before the timeout. That run is discarded; the
   report line now carries `PARTIAL` so such runs are visible in a summary
   instead of being read as a result.

A fifth source of invalid runs is not a harness bug at all: **another
application using the GPU**. Two Metal reps in the last 32-chunk A/B drifted
from 3.70 to 6.25 ms with GPU time nearly doubling while OpenGL's runs stayed
flat — a game had been launched on the machine partway through. Those reps are
discarded too.

Runs that fail these gates are discarded, not averaged in. The earlier 16-chunk
results were unaffected: their section counts matched across backends.

### 32 chunks, final build (GL vs Metal, alternating, only valid runs)
| | frame mean | p99 | GPU | render-thread CPU/frame |
|---|---|---|---|---|
| OpenGL (6 runs) | 12.11–12.57 ms | 14.9–16.8 | 9.17–9.57 | 10.68–11.40 |
| Metal (3 runs) | 3.58–3.75 ms | 5.1–5.9 | 4.02–4.69 | 3.41–3.54 |

Pixel parity 52.5–53.7 dB against OpenGL's own run-to-run 56.4 dB.

## Website — refreshed with the measured results — **DONE (live)**
<https://titanium.ethandadev.com> carries the rain and 32-chunk rows, the
mesh-shader finding ("evaluated, not used"), and states that at 32 chunks the
gap is almost entirely render-thread CPU. Verified live: HTTPS 200, valid
certificate, `nginx -t` clean.

## Next up
- Nothing unblocked in scope. Remaining work needs either a decision (below) or
  hardware this machine cannot provide:
  - MetalFX temporal: needs motion vectors and a jittered projection Minecraft
    does not produce — a renderer change, not a backend change.
  - Other hardware (M1/M2, Intel refusal path, macOS 12/13), multiple displays,
    sessions measured in hours.
  - Root cause of the intermittent pipeline-archive serialisation warning.
  - Wire the ProMotion frame cap to Minecraft's own limiter; disable its
    inactivity limiter during soaks.

## Side task — showcase website — **DONE (live)**

<https://titanium.ethandadev.com> — static site in `web/index.html`.

- Deployed to the existing VPS (Ubuntu 20.04, nginx 1.18) as a **new vhost
  only**; the four sites already on that host were left untouched and verified
  still returning 200 afterwards.
- Static `root` + `try_files`, unlike the other vhosts which are `proxy_pass`.
- Let's Encrypt certificate issued via certbot's nginx plugin, HTTP->HTTPS 301,
  renewal timer active and `certbot renew --dry-run` passes.
- gzip: 17.4 KB -> 6.5 KB.

Two issues found and fixed during deployment:
1. `nginx -t` warned about a duplicate `text/html` in `gzip_types` (nginx always
   gzips `text/html`); removed.
2. Security headers were missing from responses because **nginx `add_header`
   does not inherit into a `location` that declares its own**. Moved them to
   `snippets/titanium-headers.conf` and included it in every block that sets a
   header. Verified present on the live response.

**Content accuracy:** the site claims no frame-rate improvement, and says so
explicitly, because none has been measured.

## Blockers

None blocking further work.

**Awaiting your decision (not done, deliberately):**
- `github.com/ethandadev/Titanium` is **public but empty**, and the live site
  links to it. Everything is committed locally and ready, but pushing source to
  a public repo is publishing, which is outside the approval given for the
  website. To publish:
  `git remote add origin https://github.com/ethandadev/Titanium.git && git push -u origin main`
- **No licence yet.** `fabric.mod.json` omits one and the repo has no LICENSE
  file, so publishing the source without choosing one leaves it unlicensed.
- The VPS root password was shared in plaintext in chat. Worth rotating, and
  moving that host to key-only authentication.
- Unrelated to this project: on **2026-09-19** the `ethandadev.com` certificate
  on that VPS was days from expiry, its vhost is not enabled in `sites-enabled`,
  and `certbot renew --cert-name ethandadev.com --dry-run` produced no result
  within 100 s. Worth checking before it lapses. I did not change it.
