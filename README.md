# Titanium

A native Apple **Metal** renderer for **Minecraft: Java Edition 1.21.11** on
macOS, targeting Apple silicon.

Not a wrapper around OpenGL. Not MoltenVK. Not a Vulkan-to-Metal translation
layer. At runtime the process talks to Metal directly through an
Objective-C++ bridge.

> **Status: working pre-release.** Minecraft 1.21.11 runs on Titanium's Metal
> backend — title screen and in-world — with no OpenGL context in the process.
> In a deterministic test world, frames match stock OpenGL on 99.8–99.96% of
> pixels (within OpenGL's own run-to-run noise). The release jar has been
> verified in a production Fabric install, including automatic fallback to
> OpenGL. Tested on one machine (M3 Max, macOS 26.6.2); see
> [`PROGRESS.md`](PROGRESS.md) for exactly what has and hasn't been verified.

Website: <https://titanium.ethandadev.com>

---

## Why

Minecraft creates an **OpenGL 3.3 core** context on macOS — verified by
disassembling the 1.21.11 client, not assumed. Apple deprecated OpenGL in 2018;
it gets no driver investment and cannot express how Apple GPUs actually render.

Mojang's 1.21 rendering rewrite introduced a backend-agnostic seam
(`GpuDevice` / `CommandEncoder` / `RenderPass`) and marked it `@DontObfuscate`.
That is **57 interface methods** for a complete backend, and the OpenGL context
is created *inside* the component being replaced — so swapping the device
removes OpenGL from the process rather than leaving a dead context behind.

Everything above is reproducible:

```bash
./tools/verify-mc.sh
```

It downloads the official client jar and mappings (SHA-1 verified), then prints
the evidence for each claim in [`docs/feasibility.md`](docs/feasibility.md).

---

## Repository layout

```
native/           Metal backend (Objective-C++), builds libtitanium.dylib
  include/titanium/ti_api.h   public C ABI — deliberately FFM-shaped
  src/                        core, resources, shaders/pipelines, render
  src/ti_translate.cpp        GLSL -> SPIR-V -> MSL (glslang + SPIRV-Cross)
  src/jni/                    JNI bridge (67 entry points)
  third_party/                fetched by tools/fetch-deps.sh (gitignored)
  tests/                      native self-test + on-screen validation
mod/              Java side (JNI bindings, loader, capability model)
docs/             feasibility, architecture, support matrix, milestones
tools/            verify-mc.sh (reproduces every Minecraft-side claim)
                  fetch-deps.sh (pinned, hash-verified native dependencies)
web/              the showcase site
```

## Building

Requires macOS, Xcode command line tools, CMake, and a JDK (for the JNI headers).

```bash
./tools/fetch-deps.sh     # glslang + SPIRV-Cross at pinned, hash-verified commits
cd native && make         # builds deps, libtitanium.dylib, runs the self-test
```

The fetch needs network once; everything after is offline, and nothing is
installed system-wide. Licences: [`docs/third-party.md`](docs/third-party.md).

### Tests

```bash
cd native && make test          # 66 checks, offscreen, verifies rendered pixels
cd native && make frametest     # 67 checks: ordering, fences, views, stage profiling, draw batching
cd native && make windowtest    # 17 checks, opens a real window (needs a GUI session)
cd native && make translatetest # 50 GLSL->MSL checks, each verified by rendered pixels
cd native && make encodebench   # not a test: CPU cost per draw, for draw-path decisions
```

JVM end-to-end (JNI, zero-copy upload, pixel verification from Java):

```bash
javac --release 21 -d build/classes \
  mod/src/main/java/com/ethandadev/titanium/natives/*.java \
  mod/src/test/java/com/ethandadev/titanium/*.java

java -cp build/classes \
  -Dtitanium.native.path=native/build/libtitanium.dylib \
  com.ethandadev.titanium.JvmEndToEndTest
```

Shader preprocessor, against the real vanilla shader corpus (needs an extracted
client jar; reports SKIPPED rather than passing if absent):

```bash
./tools/verify-mc.sh                     # extracts to $TMPDIR/titanium-mc-verify/shaders
java -cp build/classes \
  com.ethandadev.titanium.ShaderPreprocessorTest "$TMPDIR/titanium-mc-verify/shaders"
java -cp build/classes -Dtitanium.native.path=native/build/libtitanium.dylib \
  com.ethandadev.titanium.ShaderCorpusTranslationTest "$TMPDIR/titanium-mc-verify/shaders"
```

The tests verify **rendered pixel values**, not just that calls returned
success — the textured-quad, depth and blending tests each read the framebuffer
back off the GPU and assert exact colours.

## Installing

1. Install Fabric Loader (0.19.0+) for Minecraft 1.21.11.
2. Put `titanium-<version>.jar` in the `mods` folder. No other files are
   needed: the native library is inside the jar and is extracted on first use.
3. Launch. The log says either `Titanium active: … on Metal` or
   `Titanium disabled: <reason>. Using the stock OpenGL renderer.`

Titanium turns itself off (and the game runs on stock OpenGL) on non-Apple-
silicon Macs, other operating systems, macOS < 12, or when an incompatible
renderer mod (Iris, Sodium, OptiFabric, Canvas) is installed.

To build the jar yourself:

```bash
./tools/fetch-deps.sh
cd mod && ./gradlew build        # builds native + jar, runs the test harnesses
```

## Runtime flags

| Property | Effect |
|---|---|
| `-Dtitanium.enabled=false` | Hard off switch; falls back to the stock renderer |
| `-Dtitanium.native.path=…` | Load a dylib from disk instead of the jar (development) |
| `-Dtitanium.worldScale=…` | Render the world at a fraction of the window and upscale (0.5–1.0) |
| `-Dtitanium.upscaler=…` | `metalfx` (default, spatial) or `bilinear` |

Diagnostics, off by default:

| Property | Effect |
|---|---|
| `-Dtitanium.profilePasses=true` | Per-pass GPU vertex/fragment stage times, by pass label |
| `-Dtitanium.batchDraws=false` | Encode chunk draws one call at a time (for A/B; see architecture §10) |
| `-Dtitanium.deferredClears=true` | Fold clears into the next pass's load action (measured: no gain here) |

## Requirements

macOS 12+ · Apple silicon · Minecraft 1.21.11 · Fabric · Java 21.
Shader packs (Iris/OptiFine) and mods that call OpenGL directly are
**not supported** — see [`docs/support-matrix.md`](docs/support-matrix.md).

## On performance

Measured against the unmodified renderer on **one machine** (M3 Max, macOS
26.6.2, 1708x960, uncapped, a frozen pre-generated world, three alternating
runs per side). These are not a general claim about other hardware, and the
caveats matter:

| Scene | OpenGL frame mean | Titanium frame mean |
|---|---|---|
| Forest canopy, 16 chunks | 5.28–5.57 ms | 1.22–1.33 ms |
| Hilltop vista, 16 chunks | 6.02–6.21 ms | 1.43–1.53 ms |
| Hilltop vista, 32 chunks | 12.11–12.57 ms | 3.58–3.75 ms |
| Hilltop vista, rain, 16 chunks | 6.27–6.72 ms | 1.67–1.80 ms |

Rendered output matches the OpenGL renderer at 99.8–99.96% of pixels, which is
the same as OpenGL's own run-to-run variation in these scenes; the GUI is
bit-identical. With vsync off Titanium skips presents the display cannot show
while OpenGL hands every frame to the window server, which is part of the
difference (architecture §7.1). Full method, percentiles and per-scene
breakdown: [`PROGRESS.md`](PROGRESS.md) and
[`docs/architecture.md`](docs/architecture.md) §8–§10.

## Licence and attribution

An independent project, not affiliated with Mojang, Microsoft or Apple.
Minecraft is a trademark of Mojang AB. Titanium contains no Minecraft code;
`tools/verify-mc.sh` downloads Mojang's own published artifacts at the user's
request and redistributes nothing.
