#!/usr/bin/env bash
# Alternating A/B of two Titanium configurations on the same frozen world.
#   ./bench/ab-toggle.sh <reps> "<A gradle -P args>" "<B gradle -P args>" [common -P args...]
#   e.g. ./bench/ab-toggle.sh 3 "-PdeferredClears=false" "-PdeferredClears=true" -Pcamera=vista
set -uo pipefail
REPS="$1"; A="$2"; B="$3"; shift 3; COMMON=("$@")
cd "$(dirname "$0")/../mod"
OUT="../bench/results/$(date +%Y%m%d-%H%M%S)-toggle"
mkdir -p "$OUT"; printf 'A: %s\nB: %s\ncommon: %s\n' "$A" "$B" "${COMMON[*]}" > "$OUT/config.txt"
for i in $(seq 1 "$REPS"); do
  for side in A B; do
    args="$A"; [ "$side" = B ] && args="$B"
    label="${side}-r${i}"
    # shellcheck disable=SC2086
    ./gradlew runClient --no-daemon -Pselfcheck="$label" -Pworld=titanium-bench -Puncapped $args "${COMMON[@]}" \
      > "$OUT/$label.log" 2>&1
    grep "SELFCHECK frametimes" "$OUT/$label.log" | sed 's/.*SELFCHECK frametimes //' | tee -a "$OUT/summary.txt"
    cp "run/screenshots/titanium-selfcheck-$label.png" "$OUT/" 2>/dev/null || true
  done
done
echo "results in $OUT"
