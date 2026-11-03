#!/usr/bin/env bash
set -euo pipefail
export CCACHE_DIR=/tmp/codex_timingopt14_ccache
mkdir -p "$CCACHE_DIR"
overlay=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
project=$(cd -- "$overlay/../.." && pwd)
base="$project/imports/new"
index_bits=${1:-8}
sources=()
for source in "$base"/*.v; do
    name=$(basename -- "$source")
    case "$name" in
        dram_cache.v|dual_issue_pairing.v|dual_issue_forwarding.v|dual_issue_lane.v) ;;
        *)
            if [[ -f "$overlay/$name" ]]; then
                sources+=("$overlay/$name")
            else
                sources+=("$source")
            fi ;;
    esac
done
result_dir="$project/sim_results/timingopt14_regression_cache${index_bits}"
if [[ -n "${RUN_LABEL:-}" ]]; then
    [[ "$RUN_LABEL" =~ ^[A-Za-z0-9_]+$ ]] || exit 2
    result_dir="${result_dir}_${RUN_LABEL}"
fi
mkdir -p "$result_dir"
tests=(tb_lane1_rv32m_pair tb_load_rv32m_dependency tb_lane1_load_pair tb_dual_issue_branch_guard tb_dual_issue_load_forward tb_compact_cache_region tb_cache_store_refill)
for top in "${tests[@]}"; do
    if [[ -n "${TEST_FILTER:-}" && "$top" != "$TEST_FILTER" ]]; then continue; fi
    build_dir=$(mktemp -d "/tmp/timingopt14_${top}.XXXXXX")
    test_file="$project/new/$top.sv"
    [[ ! -f "$overlay/$top.sv" ]] || test_file="$overlay/$top.sv"
    echo "COMPILE: $top"
    if ! verilator --binary --timing -j 4 \
        -Wno-fatal -Wno-PINMISSING -Wno-TIMESCALEMOD \
        -DDCACHE_INDEX_BITS="$index_bits" \
        -I"$overlay" -I"$base" --top-module "$top" --Mdir "$build_dir" \
        "${sources[@]}" "$test_file" > "$result_dir/${top}_build.log" 2>&1; then
        tail -n 80 "$result_dir/${top}_build.log"
        exit 1
    fi
    "$build_dir/V$top" | tee "$result_dir/${top}_run.log"
done
