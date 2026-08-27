#!/bin/bash
# verify/run_soc.sh — cnn_soc full-SoC 100-image demo run (G1-G5)
# Mirrors cnn/verify/scripts/run_tests.sh house pattern. Run from the
# cnn_soc project root:  ./verify/run_soc.sh [RUN_TAG]
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
VERIFY="$ROOT/verify"
RUN_TAG="${1:-run-$(date +%Y%m%d-%H%M%S)}"
RUN_DIR="$VERIFY/$RUN_TAG"
mkdir -p "$RUN_DIR"
DIFF_LOG="$RUN_DIR/diff.log"
SUMMARY="$RUN_DIR/summary.txt"
: > "$SUMMARY"

TB="tb_cnn_soc"
LOG="$RUN_DIR/$TB.log"

echo "--- $TB (G1-G5) ---"
if ! iverilog -g2005 -Wall -I"$ROOT" -o "$RUN_DIR/$TB.vvp" \
        "$VERIFY/tests/$TB.v" -f "$ROOT/filelist.f" > "$LOG" 2>&1; then
    echo "ERROR $TB (elaboration) — see $LOG" | tee -a "$SUMMARY"
    exit 1
fi
( cd "$ROOT" && timeout 10800 vvp "$RUN_DIR/$TB.vvp" +OUTDIR="$RUN_DIR" >> "$LOG" 2>&1 )

if grep -qE '^PASS ' "$LOG"; then
    echo "PASS $TB (G1-G5 in-sim checks)" | tee -a "$SUMMARY"
else
    echo "FAIL $TB (in-sim checks) — see $LOG" | tee -a "$SUMMARY"
fi

# ---- G1: diff captured UART vs first 100 golden lines ----
GOLDEN="$ROOT/../cnn/arch/golden_model/expected_outputs.txt"
if [ -f "$RUN_DIR/uart_captured.txt" ]; then
    head -100 "$GOLDEN" > "$RUN_DIR/golden_100.txt"
    cp "$RUN_DIR/uart_captured.txt" "$RUN_DIR/captured_all.txt"
    ok=1
    if ! diff "$RUN_DIR/golden_100.txt" "$RUN_DIR/uart_captured.txt" > "$DIFF_LOG" 2>&1; then
        ok=0
    fi
    n_cap=$(wc -l < "$RUN_DIR/uart_captured.txt")
    n_gold=$(wc -l < "$RUN_DIR/golden_100.txt")
    if [ "$n_cap" != "$n_gold" ]; then
        echo "line count: captured=$n_cap golden=$n_gold" >> "$DIFF_LOG"
        ok=0
    fi
    if [ "$ok" = "1" ]; then
        echo "PASS G1 (100/100 lines byte-exact vs expected_outputs.txt first-100, $n_cap lines)" | tee -a "$SUMMARY"
    else
        echo "FAIL G1 (UART diff) — see $DIFF_LOG" | tee -a "$SUMMARY"
    fi
else
    echo "ERROR G1: uart_captured.txt not found" | tee -a "$SUMMARY"
fi

# ---- per-gate verdict rollup from the sim log ----
for g in G2 G3 G4 G5; do
    if grep -qE "FAIL ${g}_" "$LOG"; then
        echo "FAIL $g (see $LOG)" | tee -a "$SUMMARY"
    else
        echo "PASS $g (in-sim, no ${g}_ failures)" | tee -a "$SUMMARY"
    fi
done

echo "" | tee -a "$SUMMARY"
PASS_N=$(grep -c '^PASS ' "$SUMMARY" || true)
FAIL_N=$(grep -c '^FAIL ' "$SUMMARY" || true)
echo "RESULT: PASS=$PASS_N FAIL=$FAIL_N" | tee -a "$SUMMARY"

# ---- append-only iterations.log ----
RTL_MD5=$(cd "$ROOT" && cat $(grep -v '^#' filelist.f) | md5sum | cut -d' ' -f1)
FW_MD5=$(md5sum "$ROOT/sw/firmware.hex" | cut -d' ' -f1)
echo "$RUN_TAG $(date -u +%Y-%m-%dT%H:%M:%SZ) PASS=$PASS_N FAIL=$FAIL_N rtl_md5=$RTL_MD5 fw_md5=$FW_MD5 dir=$RUN_DIR" >> "$VERIFY/iterations.log"

exit 0
