#!/usr/bin/env bash
# Alternating A/B of stock OpenGL vs Titanium on the same frozen, pre-generated
# world. Alternation spreads thermal and JIT/order effects across both backends.
#   ./bench/ab-world.sh [reps]      (default 3 of each)
set -uo pipefail
REPS="${1:-3}"
cd "$(dirname "$0")/../mod"
OUT="../bench/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUT"
for i in $(seq 1 "$REPS"); do
  for backend in opengl metal; do
    flag=""; [ "$backend" = "opengl" ] && flag="-Ptitanium=false"
    label="${backend}-r${i}"
    ./gradlew runClient --no-daemon -Pselfcheck="$label" -Pworld=titanium-bench -Puncapped $flag \
      > "$OUT/$label.log" 2>&1
    line=$(grep "SELFCHECK frametimes" "$OUT/$label.log" | sed 's/.*SELFCHECK frametimes //')
    echo "$line" | tee -a "$OUT/summary.txt"
    cp "run/screenshots/titanium-selfcheck-$label.png" "$OUT/" 2>/dev/null || true
  done
done
echo "results in $OUT"
