#!/bin/bash
#---------------------------------------------------------------------
# run_tests.sh — mnist_npu frontend verification runner (Stage 1: fe-iverilog)
# Project  : PRJ-005 mnist_npu
# Usage    : bash verify/scripts/run_tests.sh [run-dir] [test-filter]
#   run-dir : default verify/run-<NNN> (next free). Artifacts versioned.
#   filter  : substring of test name (e.g. "mac" runs only tb_mac*).
# Each test: iverilog -g2005 -Wall -I. <sources> -f filelist.f, run, verdict + log.
# Also runs the golden-model reproduction, tools/check_lut.py (VP-LUT-001
# exhaustive 65536/65536), and the byte-exact UART diff against the
# frozen arch/golden_model/expected_outputs.txt (C2/VP-TOP-004).
# Logs are append-only in verify/iterations.log (never overwritten).
#---------------------------------------------------------------------
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$ROOT/verify"

RUN_DIR="${1:-}"
if [ -z "$RUN_DIR" ]; then
    n=0
    while [ -d "$VERIFY/run-$(printf '%03d' $n)" ]; do n=$((n+1)); done
    RUN_DIR="$VERIFY/run-$(printf '%03d' $n)"
fi
mkdir -p "$RUN_DIR"
FILTER="${2:-}"

echo "== mnist_npu verify run -> $RUN_DIR (filter='${FILTER:-all}') @ $(date -u +%Y-%m-%dT%H:%M:%SZ)"

MODTESTS="tb_reset tb_rom_readback tb_sigmoid_lut_unit tb_mac_datapath_unit tb_uart_line_fmt_unit"
TOPTESTS="tb_mnist_top tb_uart_realdiv"

PASS=0; FAIL=0; ERROR=0
SUMMARY="$RUN_DIR/summary.txt"
: > "$SUMMARY"

run_one() {
    local tb="$1" label="$2"
    if [ -n "$FILTER" ] && [[ "$tb" != *"$FILTER"* ]]; then return; fi
    local log="$RUN_DIR/$tb.log"
    echo "--- $tb ---"
    if ! iverilog -g2005 -Wall -I"$ROOT" -o "$RUN_DIR/$tb.vvp" \
            "$VERIFY/tests/$tb.v" -f "$ROOT/filelist.f" > "$log" 2>&1; then
        echo "ERROR $tb (elaboration)" | tee -a "$SUMMARY"
        ERROR=$((ERROR+1))
        return
    fi
    ( cd "$ROOT" && timeout 7200 vvp "$RUN_DIR/$tb.vvp" +OUTDIR="$RUN_DIR" >> "$log" 2>&1 )
    if grep -qE '^PASS ' "$log"; then
        echo "PASS $tb ($label)" | tee -a "$SUMMARY"
        PASS=$((PASS+1))
    elif grep -qE '^FAIL ' "$log"; then
        echo "FAIL $tb ($label) — see $log" | tee -a "$SUMMARY"
        FAIL=$((FAIL+1))
    else
        echo "ERROR $tb (no verdict in log — timeout/hang?)" | tee -a "$SUMMARY"
        ERROR=$((ERROR+1))
    fi
}

for t in $MODTESTS; do
    case "$t" in
        tb_reset)            run_one "$t" "VP-TOP-001" ;;
        tb_rom_readback)     run_one "$t" "VP-ROM-001" ;;
        tb_sigmoid_lut_unit) run_one "$t" "VP-LUT-002" ;;
        tb_mac_datapath_unit) run_one "$t" "VP-MAC-001/002/003" ;;
        tb_uart_line_fmt_unit) run_one "$t" "VP-UART-001" ;;
    esac
done

for t in $TOPTESTS; do
    case "$t" in
        tb_mnist_top)   run_one "$t" "VP-TOP-002..008/VP-LED-001..003/VP-CTRL-001/C1,C3-C7" ;;
        tb_uart_realdiv) run_one "$t" "VP-UART-002 real CLK_DIV=868" ;;
    esac
done

# ---- VP-LUT-001: exhaustive 65536/65536 sigmoid LUT check (Python, not Verilog) ----
LUT_LOG="$RUN_DIR/check_lut.log"
if [ -z "$FILTER" ] || [[ "check_lut" == *"$FILTER"* ]]; then
    echo "--- check_lut.py (VP-LUT-001) ---"
    if ( cd "$ROOT" && python3 tools/check_lut.py rtl/sigmoid_lut.hex > "$LUT_LOG" 2>&1 ); then
        echo "PASS check_lut.py (VP-LUT-001 exhaustive 65536/65536)" | tee -a "$SUMMARY"
        PASS=$((PASS+1))
    else
        echo "FAIL check_lut.py (VP-LUT-001) — see $LUT_LOG" | tee -a "$SUMMARY"
        FAIL=$((FAIL+1))
    fi
fi

# ---- C2/VP-TOP-004: byte-exact UART stream diff against the frozen golden text ----
if [ -z "$FILTER" ] || [[ "uart_diff" == *"$FILTER"* ]]; then
    echo "--- uart_captured.txt vs golden expected_outputs.txt (C2) ---"
    DIFF_LOG="$RUN_DIR/uart_diff.log"
    : > "$DIFF_LOG"
    if [ -f "$RUN_DIR/uart_captured.txt" ]; then
        head -100 "$ROOT/arch/golden_model/expected_outputs.txt" > "$RUN_DIR/golden_100.txt"
        head -100 "$RUN_DIR/uart_captured.txt" > "$RUN_DIR/captured_pass1.txt"
        tail -100 "$RUN_DIR/uart_captured.txt" > "$RUN_DIR/captured_pass2.txt"
        ok=1
        if ! diff -q "$RUN_DIR/captured_pass1.txt" "$RUN_DIR/golden_100.txt" >> "$DIFF_LOG" 2>&1; then ok=0; fi
        if ! diff -q "$RUN_DIR/captured_pass2.txt" "$RUN_DIR/golden_100.txt" >> "$DIFF_LOG" 2>&1; then ok=0; fi
        if [ "$(wc -l < "$RUN_DIR/uart_captured.txt")" != "200" ]; then ok=0; echo "expected 200 lines, got $(wc -l < "$RUN_DIR/uart_captured.txt")" >> "$DIFF_LOG"; fi
        if [ "$ok" = "1" ]; then
            echo "PASS uart_diff (C2/VP-TOP-004: 200/200 lines byte-exact vs golden, both passes)" | tee -a "$SUMMARY"
            PASS=$((PASS+1))
        else
            echo "FAIL uart_diff (C2/VP-TOP-004) — see $DIFF_LOG" | tee -a "$SUMMARY"
            FAIL=$((FAIL+1))
        fi
    else
        echo "ERROR uart_diff: $RUN_DIR/uart_captured.txt not found (tb_mnist_top did not run?)" | tee -a "$SUMMARY"
        ERROR=$((ERROR+1))
    fi
fi

echo "" | tee -a "$SUMMARY"
echo "RESULT: PASS=$PASS FAIL=$FAIL ERROR=$ERROR" | tee -a "$SUMMARY"

# ---- append-only iterations.log with RTL md5 + notes ----
RTL_MD5=$(cd "$ROOT" && cat $(grep -v '^#' filelist.f) rtl/mnist_npu_defs.vh | md5sum | cut -d' ' -f1)
echo "$(basename "$RUN_DIR") $(date -u +%Y-%m-%dT%H:%M:%SZ) PASS=$PASS FAIL=$FAIL ERROR=$ERROR tests=${FILTER:-all} rtl_md5=$RTL_MD5 dir=$RUN_DIR" >> "$VERIFY/iterations.log"

exit 0
