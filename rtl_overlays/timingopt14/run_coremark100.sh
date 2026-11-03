#!/usr/bin/env bash
set -euo pipefail
export CCACHE_DIR=/tmp/codex_timingopt14_ccache
mkdir -p "$CCACHE_DIR"

overlay=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project=$(cd -- "$overlay/../.." && pwd)
index_bits=${1:-8}
clock_hz=${2:-200000000}
mem_dir=${3:-$project/sim}
[[ "$index_bits" =~ ^[6-9]$ ]] || { echo 'index_bits must be 6..9' >&2; exit 2; }
[[ "$clock_hz" =~ ^[0-9]+$ ]] || exit 2
variant="cache${index_bits}_${clock_hz}Hz"
if [[ -n "${RUN_LABEL:-}" ]]; then
    [[ "$RUN_LABEL" =~ ^[A-Za-z0-9_]+$ ]] || exit 2
    variant="${RUN_LABEL}_${variant}"
fi
result_dir="$project/sim_results/timingopt14_$variant"
build_dir=$(mktemp -d "/tmp/timingopt14_${variant}_build.XXXXXX")
run_dir=$(mktemp -d "/tmp/timingopt14_${variant}_run.XXXXXX")
mkdir -p "$result_dir"
ln -s "$mem_dir" "$run_dir/sim"
sources=()
while IFS= read -r relative_source; do
    [[ -n "$relative_source" ]] || continue
    overlay_source="$overlay/$(basename -- "$relative_source")"
    if [[ -f "$overlay_source" ]]; then
        sources+=("$overlay_source")
    else
        sources+=("$project/$relative_source")
    fi
done < "$project/new/tb_coremark100_dual.f"

printf 'CoreMark: index_bits=%s clock_hz=%s build=%s\n' "$index_bits" "$clock_hz" "$build_dir"
sha256sum "$mem_dir/irom.mem" "$mem_dir/dram.mem" > "$result_dir/memory_sha256.txt"
sha256sum "${sources[@]}" "$overlay/dram_cache.v" "$overlay/dual_issue_pairing.v" \
    "$project/imports/new/dual_issue_forwarding.v" "$project/imports/new/dual_issue_lane.v" \
    > "$result_dir/source_sha256.txt"
if ! verilator --binary --timing -O3 -j 4 \
    -Wno-fatal -Wno-PINMISSING -Wno-TIMESCALEMOD \
    -DDCACHE_INDEX_BITS="$index_bits" -DTB_CPU_CLK_HZ="$clock_hz" \
    -I"$overlay" -I"$project/imports/new" \
    --top-module tb_coremark100_dual --Mdir "$build_dir" \
    "${sources[@]}" > "$result_dir/build.log" 2>&1; then
    tail -n 80 "$result_dir/build.log"
    exit 1
fi
(cd "$run_dir" && "$build_dir/Vtb_coremark100_dual") 2>&1 | tee "$result_dir/run.log"
