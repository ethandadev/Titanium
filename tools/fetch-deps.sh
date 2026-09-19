#!/usr/bin/env bash
# Fetch Titanium's native third-party sources at pinned, verified commits.
#
#   ./tools/fetch-deps.sh
#
# Integrity is checked against the git COMMIT hash rather than a tarball hash:
# GitHub's generated archives are not guaranteed byte-stable over time, but a
# commit hash is a content hash of the entire tree and cannot drift.
#
# Sources land in native/third_party/ (gitignored). After one fetch the build
# is fully offline.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/native/third_party"
mkdir -p "$DEST"

# name | repository | tag | expected commit
DEPS=(
  "glslang|https://github.com/KhronosGroup/glslang.git|vulkan-sdk-1.4.357.0|168d452a4f460d24b588fed08477a81c44ee27a1"
  "SPIRV-Cross|https://github.com/KhronosGroup/SPIRV-Cross.git|vulkan-sdk-1.4.357.0|6c09849fe88c48eaed08413aa022aaa136a3a057"
)

for entry in "${DEPS[@]}"; do
  IFS='|' read -r name repo tag want <<<"$entry"
  dir="$DEST/$name"

  if [ -d "$dir/.git" ]; then
    have=$(git -C "$dir" rev-parse HEAD)
    if [ "$have" = "$want" ]; then
      echo "  ok      $name @ $tag (${want:0:12}) already present"
      continue
    fi
    echo "  stale   $name is at ${have:0:12}, want ${want:0:12}; refetching"
    rm -rf "$dir"
  fi

  echo "  fetch   $name @ $tag"
  git clone --quiet --depth 1 --branch "$tag" -c advice.detachedHead=false "$repo" "$dir"
  have=$(git -C "$dir" rev-parse HEAD)
  if [ "$have" != "$want" ]; then
    echo "  FAILED  $name: tag $tag resolved to $have, expected $want" >&2
    echo "          Refusing to build against an unverified source tree." >&2
    rm -rf "$dir"
    exit 1
  fi
  echo "  ok      $name verified at ${want:0:12}"
done
