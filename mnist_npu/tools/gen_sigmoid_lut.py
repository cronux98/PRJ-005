#!/usr/bin/env python3
"""gen_sigmoid_lut.py — mnist_npu (fe-rtl stage)

Deterministically generates rtl/sigmoid_lut.hex: a 65536-entry x 8-bit
$readmemh-loadable ROM table for the golden model's rational sigmoid
approximation, bit-exact per arch/golden_model/README.md and
golden_ref_model.c:

    sigma(z) = 128 + trunc(128*z / (256+|z|))   (C99 truncation toward zero)

Address = the raw 16-bit two's-complement bit pattern of the signed Q8.8
value z (address 0..32767 => z = address; address 32768..65535 => z =
address - 65536), matching sigmoid_lut's IFI-002 `lut_addr` contract
(arch/interface_defs.yaml) and REQ-006 (spec/requirements.yaml).

No floating point is used anywhere in this generator (matches golden model's
integer-only discipline). Output: one 2-hex-digit word per line, no "0x"
prefix, LF line endings — exactly the shape iverilog's $readmemh expects and
identical in format convention to arch/golden_model/*.hex.

Usage:
    python3 tools/gen_sigmoid_lut.py [output_path]
    (default output_path: rtl/sigmoid_lut.hex, relative to the project root
    this script is invoked from — run from mnist_npu/)
"""
import sys
import os


def c99_trunc_div(num: int, den: int) -> int:
    """Integer division truncating toward zero, matching C99 '/' on ints."""
    q = abs(num) // abs(den)
    if (num < 0) != (den < 0):
        q = -q
    return q


def sigmoid(z: int) -> int:
    num = 128 * z
    den = 256 + abs(z)
    return 128 + c99_trunc_div(num, den)


def main() -> int:
    out_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join("rtl", "sigmoid_lut.hex")
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)

    lines = []
    for addr in range(65536):
        z = addr if addr < 32768 else addr - 65536
        sigma = sigmoid(z)
        assert 0 <= sigma <= 255, f"sigma out of 8-bit range at z={z}: {sigma}"
        lines.append("%02x" % sigma)

    with open(out_path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    print(f"wrote {len(lines)} entries to {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
