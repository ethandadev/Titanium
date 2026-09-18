# Titanium — Support Matrix

Status key: **verified** = tested on real hardware and the result recorded ·
**expected** = should work by construction but untested · **unsupported** =
will refuse to enable.

## Platform

| Axis | Requirement | Status |
|---|---|---|
| Operating system | macOS 12.0+ (deployment target) | macOS 26.6.2 **verified**; 12–25 **expected** |
| Architecture | Apple silicon (`arm64`) | **verified** on M3 Max |
| Intel Mac | — | **unsupported**; `NativeLoader` refuses with an actionable message |
| GPU | Apple-family, unified memory | **verified** (Apple family 9) |
| Minecraft | 1.21.11 | seam **verified** against the real client jar |
| Mod loader | Fabric | integration **not yet built** |
| Java | 21 (launcher `java-runtime-delta`) | **verified** on OpenJDK 21.0.3; also runs on 25 |

Titanium's native library links **MetalFX weakly**, so it loads on macOS 12
where MetalFX does not exist; the capability probe simply reports it absent.

## Feature gates

Every row is decided by a runtime query against the live `MTLDevice`, never
inferred from chip name or OS version.

| Feature | Gate | On M3 Max / macOS 26.6.2 |
|---|---|---|
| Metal 3 family | `supportsFamily(Metal3)` | yes |
| Metal 4 family | `supportsFamily(5002)` | yes |
| Unified memory | `hasUnifiedMemory` | yes |
| Memoryless attachments | `supportsFamily(Apple1)` | yes |
| Programmable blending | `supportsFamily(Apple1)` | yes |
| Mesh shaders | `supportsFamily(Apple7)` or Metal3+Mac2 | yes |
| Ray tracing | `supportsRaytracing` | yes |
| Argument buffers | `argumentBuffersSupport` | tier 2 |
| `Depth24Unorm_Stencil8` | `isDepth24Stencil8PixelFormatSupported` | **no** — mapped to `Depth32Float_Stencil8` |
| MetalFX spatial | `MTLFXSpatialScalerDescriptor.supportsDevice` | yes |
| MetalFX temporal | `MTLFXTemporalScalerDescriptor.supportsDevice` | yes (device-capable; **Titanium cannot use it yet** — no motion vectors) |
| Variable refresh | `NSScreen.min/maximumRefreshInterval` | yes, 120 Hz |

Measured limits on this machine: max buffer 21.06 GiB, recommended working set
28.08 GiB, max 2D texture 16384.

## Mod compatibility

| Category | Status | Why |
|---|---|---|
| Ordinary content mods | **expected** compatible | They do not touch the graphics API. |
| Mods calling LWJGL OpenGL directly | **unsupported** | With `GLFW_CLIENT_API = GLFW_NO_API` there is no GL context to call into. |
| Iris / OptiFine shader packs | **unsupported** | They inject GLSL *and* call GL directly. Titanium detects them at startup and stays disabled. |
| Sodium and similar renderers | **unsupported for now** | They replace chunk rendering at a layer below the seam. Coexistence needs design work, not a flag. |
| Resource packs replacing shaders | **expected** compatible | Overridden GLSL goes through the same translation path; only the cache key changes. |
| Resource packs (textures/models) | **expected** compatible | Not graphics-API dependent. |

## Behaviour on an unsupported system

`NativeLoader.check()` never throws and never loads native code on a machine it
cannot serve. It returns a reason string, and the mod falls back to the stock
OpenGL renderer with one actionable log line. Checks run cheapest-first:
kill switch → OS → architecture → library load → Metal probe → OS version →
Apple-silicon check. *(Verified: each branch returns rather than throwing.)*
