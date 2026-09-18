# Titanium

A native Apple **Metal** renderer for **Minecraft: Java Edition 1.21.11** on
macOS, targeting Apple silicon.

Not a wrapper around OpenGL. Not MoltenVK. Not a Vulkan-to-Metal translation
layer. At runtime the process talks to Metal directly through an
Objective-C++ bridge.

> **Status: in development.** The native Metal backend, the JNI bridge and the
> on-screen presentation path are built and tested (151 checks passing on an
> M3 Max). The GLSL→MSL translation layer and the Fabric integration are not
> written yet, so **Titanium does not yet render Minecraft.** See
> [`PROGRESS.md`](PROGRESS.md) for exactly what works.

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
  src/jni/                    JNI bridge (62 entry points)
  tests/                      native self-test + on-screen validation
mod/              Java side (JNI bindings, loader, capability model)
docs/             feasibility, architecture, support matrix, milestones
tools/            verify-mc.sh — reproduces every Minecraft-side claim
web/              the showcase site
```

## Building

Requires macOS, Xcode command line tools, and a JDK (for the JNI headers).
No third-party dependencies, no package manager, no network.

```bash
cd native && make
```

Produces `native/build/libtitanium.dylib` and runs the self-test.

### Tests

```bash
cd native && make test          # 66 checks, offscreen, verifies rendered pixels
cd native && make windowtest    # 17 checks, opens a real window (needs a GUI session)
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
./tools/verify-mc.sh                     # extracts to $TMPDIR/titanium-mc-verify
java -cp build/classes \
  com.ethandadev.titanium.ShaderPreprocessorTest "$TMPDIR/titanium-mc-verify/shaders"
```

The tests verify **rendered pixel values**, not just that calls returned
success — the textured-quad, depth and blending tests each read the framebuffer
back off the GPU and assert exact colours.

## Runtime flags

| Property | Effect |
|---|---|
| `-Dtitanium.enabled=false` | Hard off switch; falls back to the stock renderer |
| `-Dtitanium.native.path=…` | Load a dylib from disk instead of the jar (development) |

## Requirements

macOS 12+ · Apple silicon · Minecraft 1.21.11 · Fabric · Java 21.
Shader packs (Iris/OptiFine) and mods that call OpenGL directly are
**not supported** — see [`docs/support-matrix.md`](docs/support-matrix.md).

## On performance

Titanium publishes **no frame-rate comparisons**, because none have been
measured against the unmodified renderer. The numbers in `PROGRESS.md` are
native-harness microbenchmarks and say nothing about in-game performance.
Claims will appear when M5 has run, with scene, settings, hardware and
percentiles stated.

## Licence and attribution

An independent project, not affiliated with Mojang, Microsoft or Apple.
Minecraft is a trademark of Mojang AB. Titanium contains no Minecraft code;
`tools/verify-mc.sh` downloads Mojang's own published artifacts at the user's
request and redistributes nothing.
