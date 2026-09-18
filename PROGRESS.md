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

## Next up
- M2: GLSL→MSL translation layer (glslang + SPIRV-Cross) with reflection-driven
  binding assignment.
- M3: `GpuDevice`/`CommandEncoder`/`RenderPass` implementations + Fabric mixins.
- M4: capability-gated optimisations (MetalFX spatial first; temporal only
  after motion vectors exist).
- M5: A/B benchmarking against the unmodified GL renderer.

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
- Unrelated to this project: the `ethandadev.com` certificate on that VPS
  expires in **3 days**, its vhost is not enabled in `sites-enabled`, and
  `certbot renew --cert-name ethandadev.com --dry-run` produced no result
  within 100 s. Worth checking before it lapses. I did not change it.
