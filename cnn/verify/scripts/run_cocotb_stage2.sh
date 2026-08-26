#!/bin/bash
#---------------------------------------------------------------------
# run_cocotb_stage2.sh — mnist_npu Stage 2 (fe-cocotb independent harness)
# Wraps the fe-cocotb skill's run_cocotb.sh with this project's filelist
# (verify/tests/cocotb_filelist.f — absolute paths + +incdir+ for
# mnist_npu_defs.vh, since cocotb's Makefile flow runs from an arbitrary
# OUTDIR), toplevel (the TB-side mnist_npu_cocotb_wrapper.v, which
# overrides the ROM $readmemh paths to absolute so runtime CWD doesn't
# matter either), and test module (test_mnist_top.py).
#---------------------------------------------------------------------
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VERIFY="$ROOT/verify"
OUTDIR="${1:-$VERIFY/run_cocotb}"
mkdir -p "$OUTDIR"

# cocotb's Makefile.sim looks for the test module alongside the Makefile
# (fe-regression skill's "cocotb make-CWD rule") — copy it in, and purge
# any stale __pycache__ that could carry old absolute paths.
rm -rf "$OUTDIR/__pycache__"
cp "$VERIFY/tests/test_mnist_top.py" "$OUTDIR/"

# iverilog compiles with CWD=$OUTDIR (per cocotb's generated Makefile); the
# leaf ROM modules' `include "rtl/mnist_npu_defs.vh" needs that relative
# path to resolve. run_cocotb.sh's --filelist +incdir+ line didn't reach
# iverilog cleanly through cocotb's generated cmds.f in testing, so mirror
# the header at a CWD-relative path instead (default include search checks
# CWD) — simpler and doesn't depend on Makefile-generation internals.
mkdir -p "$OUTDIR/rtl"
cp "$ROOT/rtl/mnist_npu_defs.vh" "$OUTDIR/rtl/"

export PATH="$HOME/.local/bin:$PATH"

bash ~/.openclaw/workspace/skills/fe-cocotb/scripts/run_cocotb.sh \
    --filelist "$VERIFY/tests/cocotb_filelist.f" \
    --top mnist_npu_cocotb_wrapper \
    --test test_mnist_top \
    --sim icarus \
    --outdir "$OUTDIR"
rc=$?

# fe-cocotb's run_cocotb.sh needs the test module importable: copy it in
# (cocotb make-CWD rule per fe-regression skill's lesson #4).
exit $rc
