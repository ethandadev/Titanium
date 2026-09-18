#!/usr/bin/env bash
# Reproduces every Minecraft-side claim in docs/feasibility.md from the real
# 1.21.11 artifacts. Requires: curl, unzip, javap (any JDK), shasum.
#
#   ./tools/verify-mc.sh [workdir]
#
# Downloads ~43 MB on first run and caches it in the work directory.
set -euo pipefail

WORK="${1:-${TMPDIR:-/tmp}/titanium-mc-verify}"
JAR_SHA="ba2df812c2d12e0219c489c4cd9a5e1f0760f5bd"
MAP_SHA="031a68bebf55d824f66d6573d8c752f0e1bf232a"
JAR_URL="https://piston-data.mojang.com/v1/objects/${JAR_SHA}/client.jar"
MAP_URL="https://piston-data.mojang.com/v1/objects/${MAP_SHA}/client.txt"

mkdir -p "$WORK"
cd "$WORK"

fetch() { # name url expected_sha
  local name="$1" url="$2" want="$3" got=""
  if [ -f "$name" ]; then
    got=$(shasum "$name" | cut -d' ' -f1)
    [ "$got" = "$want" ] && { echo "  cached  $name"; return 0; }
    echo "  stale   $name (re-downloading)"; rm -f "$name"
  fi
  for attempt in 1 2 3 4 5; do
    curl -sS --http1.1 --retry 5 --retry-all-errors \
         --speed-time 45 --speed-limit 5000 -o "$name" "$url" || true
    got=$(shasum "$name" 2>/dev/null | cut -d' ' -f1 || echo "")
    [ "$got" = "$want" ] && { echo "  ok      $name (sha1 verified)"; return 0; }
    echo "  retry   $name (attempt $attempt gave ${got:-nothing})"
    rm -f "$name"
  done
  echo "  FAILED  could not fetch a valid $name" >&2
  return 1
}

echo "==> Fetching official artifacts into $WORK"
fetch client.jar "$JAR_URL" "$JAR_SHA"
fetch client.txt "$MAP_URL" "$MAP_SHA"

echo
echo "==> Claim 1: the render abstraction survives obfuscation (@DontObfuscate)"
grep -E "^com\.mojang\.blaze3d\.(systems|textures|buffers|pipeline)\.[A-Za-z]+ -> com\.mojang" \
     client.txt | sed 's/^/  /' | head -20

echo
echo "==> Claim 2: the OpenGL backend IS obfuscated (it is an implementation detail)"
grep -E "^com\.mojang\.blaze3d\.opengl\.GlDevice ->" client.txt | sed 's/^/  /'

echo
echo "==> Extracting classes"
rm -rf x && mkdir x && (cd x && unzip -o -q ../client.jar -x 'assets/*' 'data/*' '*.png')
echo "  $(find x -name '*.class' | wc -l | tr -d ' ') classes"

echo
echo "==> Claim 3: backend surface sizes"
for c in com.mojang.blaze3d.systems.GpuDevice \
         com.mojang.blaze3d.systems.CommandEncoder \
         com.mojang.blaze3d.systems.RenderPass; do
  n=$(javap -p -classpath x "$c" 2>/dev/null | grep -cE "^  (public|abstract).*\(" || true)
  printf "  %-46s %s methods\n" "$c" "$n"
done

echo
echo "==> Claim 4: RenderSystem.initRenderer constructs GlDevice and assigns DEVICE"
javap -c -p -classpath x com.mojang.blaze3d.systems.RenderSystem 2>/dev/null \
  | awk '/public static void initRenderer/,/^$/' \
  | grep -E "new|invokespecial|putstatic" | head -4 | sed 's/^/  /'

echo
echo "==> Claim 5: GL context creation is confined to the OpenGL backend"
for m in glfwMakeContextCurrent createCapabilities glfwSwapBuffers glfwGetCocoaWindow; do
  printf "  %-24s " "$m"
  grep -rl --binary-files=text "$m" x --include='*.class' 2>/dev/null \
    | sed 's#^x/##; s#\.class$##' | tr '\n' ' '
  echo
done
echo "  (fxe = GlDevice, fye = MacosUtil — see the mappings)"

echo
echo "==> Claim 6: Minecraft ships GLSL, so Metal needs source translation"
printf "  shader files: "; unzip -l client.jar | grep -cE "shaders/.*\.(vsh|fsh|glsl)$"
echo "  sample uniform block:"
unzip -p client.jar assets/minecraft/shaders/include/dynamictransforms.glsl | sed 's/^/    /'

echo
echo "==> Claim 7: the window is created with an OpenGL 3.3 core context"
javap -c -p -classpath x fyk 2>/dev/null \
  | awk '/glfwDefaultWindowHints/,/glfwCreateWindow/' \
  | grep -E "ldc|iconst" | head -12 | sed 's/^/  /'
cat <<'NOTE'
  Decoded: 139265=GLFW_CLIENT_API -> 196609=GLFW_OPENGL_API
           139266/139267=CONTEXT_VERSION 3.3
           139272=OPENGL_PROFILE -> 204801=CORE_PROFILE
           139270=OPENGL_FORWARD_COMPAT -> 1
NOTE

echo
echo "All checks executed. Compare against docs/feasibility.md."
