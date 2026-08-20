#!/bin/bash
#---------------------------------------------------------------------
# run_tests.sh — rinriAI verification runner (module gates + top tests)
# Project  : PRJ-005 (rinriAI) — frontend verification infrastructure
# Usage    : bash verify/scripts/run_tests.sh [run-dir] [test-filter]
#   run-dir : default verify/run-<NNN> (next free). Artifacts versioned.
#   filter  : substring of test name (e.g. "apb" runs only tb_apb*).
# Each test: iverilog -g2001 -Wall -Iverify, run, verdict + log.
# Logs are append-only in verify/iterations.log (never overwritten).
#---------------------------------------------------------------------
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$ROOT/verify"

# next run dir
RUN_DIR="${1:-}"
if [ -z "$RUN_DIR" ]; then
    n=0
    while [ -d "$VERIFY/run-$(printf '%03d' $n)" ]; do n=$((n+1)); done
    RUN_DIR="$VERIFY/run-$(printf '%03d' $n)"
fi
mkdir -p "$RUN_DIR"
FILTER="${2:-}"

echo "== rinriAI verify run -> $RUN_DIR (filter='${FILTER:-all}') @ $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# module-level gates (Phase A)
MODTESTS="tb_apb_regs tb_sample_stream tb_weight_ram tb_stats tb_div_seq"
# top-level tests (Phase B)
TOPTESTS="tb_learn_accel tb_top_regs tb_top_control tb_top_edge tb_top_lrsweep tb_top_cfg tb_top_soak tb_top_throughput"

PASS=0; FAIL=0; ERROR=0
SUMMARY="$RUN_DIR/summary.txt"
: > "$SUMMARY"

run_one() {
    local tb="$1" extra="$2" label="$3"
    if [ -n "$FILTER" ] && [[ "$tb" != *"$FILTER"* ]]; then return; fi
    local log="$RUN_DIR/$tb.log"
    echo "--- $tb ---"
    if ! iverilog -g2001 -Wall -I"$VERIFY" -o "$RUN_DIR/$tb.vvp" \
            "$VERIFY/tests/$tb.v" $extra > "$log" 2>&1; then
        echo "ERROR $tb (elaboration)" | tee -a "$SUMMARY"
        ERROR=$((ERROR+1))
        return
    fi
    ( cd "$ROOT" && "$RUN_DIR/$tb.vvp" >> "$log" 2>&1 )
    if grep -qE '^PASS ' "$log"; then
        echo "PASS $tb ($label)" | tee -a "$SUMMARY"
        PASS=$((PASS+1))
    elif grep -qE '^FAIL ' "$log"; then
        echo "FAIL $tb ($label) — see $log" | tee -a "$SUMMARY"
        FAIL=$((FAIL+1))
    else
        echo "ERROR $tb (no verdict in log)" | tee -a "$SUMMARY"
        ERROR=$((ERROR+1))
    fi
}

for t in $MODTESTS; do
    case "$t" in
        tb_apb_regs)  run_one "$t" "rtl/apb_regs.v rtl/weight_ram.v" "VP-APB-001/002" ;;
        tb_sample_stream) run_one "$t" "rtl/sample_stream.v" "VP-SIN-001/002" ;;
        tb_weight_ram) run_one "$t" "rtl/weight_ram.v" "VP-WMEM-001/002" ;;
        tb_stats)     run_one "$t" "rtl/stats.v" "VP-STAT-001" ;;
        tb_div_seq)   run_one "$t" "rtl/div_seq.v" "BLK-007 numeric edges" ;;
    esac
done

# Phase B tests (populated when the top-level suite lands)
for t in $TOPTESTS; do
    case "$t" in
        tb_learn_accel)  run_one "$t" "$(grep -v '^#' "$ROOT/filelist.f" | tr '\n' ' ')" "acceptance: VP-TOP-004/005/011, REQ-011" ;;
        tb_top_regs)     run_one "$t" "$(grep -v '^#' "$ROOT/filelist.f" | tr '\n' ' ')" "VP-TOP-001/002/003/009/010" ;;
        tb_top_control)  run_one "$t" "$(grep -v '^#' "$ROOT/filelist.f" | tr '\n' ' ')" "VP-TOP-006/007/008" ;;
        tb_top_edge)     run_one "$t" "$(grep -v '^#' "$ROOT/filelist.f" | tr '\n' ' ')" "VP-LRN-004, OI-008, L4 labels" ;;
        tb_top_lrsweep)  run_one "$t" "$(grep -v '^#' "$ROOT/filelist.f" | tr '\n' ' ')" "VP-TOP-011" ;;
        tb_top_cfg)      run_one "$t" "$(grep -v '^#' "$ROOT/filelist.f" | tr '\n' ' ')" "VP-TOP-015 8x4x3" ;;
        tb_top_soak)     run_one "$t" "$(grep -v '^#' "$ROOT/filelist.f" | tr '\n' ' ')" "VP-TOP-013 10k LFSR" ;;
        tb_top_throughput) run_one "$t" "$(grep -v '^#' "$ROOT/filelist.f" | tr '\n' ' ')" "VP-TOP-012 tiny" ;;
    esac
done

echo "" | tee -a "$SUMMARY"
echo "RESULT: PASS=$PASS FAIL=$FAIL ERROR=$ERROR" | tee -a "$SUMMARY"

# append-only iterations.log
{
    echo "$(basename "$RUN_DIR") $(date -u +%Y-%m-%dT%H:%M:%SZ) PASS=$PASS FAIL=$FAIL ERROR=$ERROR tests=${FILTER:-all} dir=$RUN_DIR"
} >> "$VERIFY/iterations.log"

exit $(( FAIL + ERROR > 0 ? 1 : 0 ))
