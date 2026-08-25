#!/usr/bin/env python3
"""check_lut.py — mnist_npu (fe-rtl stage)

Verifies rtl/sigmoid_lut.hex against the golden model's sigmoid formula for
ALL 65536 possible 16-bit signed addresses (REQ-006, spec/requirements.yaml;
VP-LUT-001, spec/verification_plan.md). This check MUST PASS before fe-rtl is
considered complete (project brief §5, §8).

Usage:
    python3 tools/check_lut.py [lut_hex_path]
    (default: rtl/sigmoid_lut.hex, relative to the project root this script
    is invoked from — run from mnist_npu/)

Exit code 0 and "PASS" on 65536/65536 match; exit code 1 and "FAIL" with the
first mismatches listed otherwise.
"""
import sys
import os


def c99_trunc_div(num: int, den: int) -> int:
    q = abs(num) // abs(den)
    if (num < 0) != (den < 0):
        q = -q
    return q


def sigmoid(z: int) -> int:
    num = 128 * z
    den = 256 + abs(z)
    return 128 + c99_trunc_div(num, den)


def main() -> int:
    lut_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join("rtl", "sigmoid_lut.hex")

    if not os.path.isfile(lut_path):
        print(f"FAIL: LUT file not found: {lut_path}")
        return 1

    with open(lut_path) as f:
        lines = [ln.strip() for ln in f if ln.strip() != ""]

    if len(lines) != 65536:
        print(f"FAIL: expected 65536 entries, found {len(lines)} in {lut_path}")
        return 1

    mismatches = []
    for addr in range(65536):
        z = addr if addr < 32768 else addr - 65536
        expected = sigmoid(z)
        got = int(lines[addr], 16)
        if got != expected:
            mismatches.append((addr, z, expected, got))
            if len(mismatches) >= 20:
                break

    if mismatches:
        print(f"FAIL: {len(mismatches)}+ mismatches found (showing up to 20):")
        for addr, z, expected, got in mismatches:
            print(f"  addr=0x{addr:04x} z={z:6d} expected=0x{expected:02x} got=0x{got:02x}")
        return 1

    print(f"PASS: {lut_path} matches golden sigmoid(z) bit-exactly for all 65536/65536 addresses")
    return 0


if __name__ == "__main__":
    sys.exit(main())
