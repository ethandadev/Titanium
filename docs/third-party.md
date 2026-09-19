# Third-party components

Titanium's native library statically links two Khronos compilers. Both are
fetched at **pinned commits** by `tools/fetch-deps.sh`, which verifies the git
commit hash and refuses to build against anything else.

| Component | Pinned at | Commit | Used for |
|---|---|---|---|
| glslang | `vulkan-sdk-1.4.357.0` | `168d452a4f46…` | GLSL 330 → SPIR-V |
| SPIRV-Cross | `vulkan-sdk-1.4.357.0` | `6c09849fe88c…` | SPIR-V → MSL, reflection |

Both are built as static archives with hidden symbol visibility. Verified:
`nm -gU libtitanium.dylib` exports **zero** glslang or SPIRV-Cross symbols, so
Titanium cannot collide with another mod that bundles its own copy.

SPIRV-Tools (glslang's optional optimiser) is **not** built or linked
(`ENABLE_OPT=OFF`), nor are HLSL support, the glslang binaries, or any tests.

## Licences

*This is a reading of the licence files shipped in each repository, recorded so
the obligations are visible. It is not legal advice.*

### SPIRV-Cross
Apache-2.0 (`LICENSE`); the source files used carry
`SPDX-License-Identifier: Apache-2.0 OR MIT`. Redistribution requires shipping
the licence text and any NOTICE content.

### glslang
`LICENSE.txt` is a composite. glslang "proper" is covered by the 3-Clause BSD
licence, with parts under 2-Clause BSD, MIT, and Apache-2.0.

The file also contains **GPL-3.0 "with special bison exception"**. It applies
to `glslang/MachineIndependent/glslang_tab.cpp`, a Bison-generated parser that
**is** compiled into `libglslang.a` (its `yyparse` tables are present in the
archive). That file carries the standard Bison exception (lines 21–31):

> As a special exception, you may create a larger work that contains part or
> all of the Bison parser skeleton and distribute that work under terms of your
> choice, so long as that work isn't itself a parser generator …

Titanium is not a parser generator, so the exception applies and the GPL's
copyleft terms do not extend to Titanium.

### Packaging obligation (M6)
Every distributed jar must include the full `LICENSE.txt` of glslang and the
`LICENSE` of SPIRV-Cross. `make licenses` copies them into
`native/build/licenses/` for the packaging step to embed.
