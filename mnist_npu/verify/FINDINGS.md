# mnist_npu — Verification Findings

Frontend verification agent (fe-iverilog / fe-cocotb / fe-regression). RTL is
FROZEN (commit ae9b07d) — findings are reported, not patched, per the
verification task's hard rules.

## FINDING-001 (RTL): `led[0]` reads 1 (not 0) throughout reset — REQ-030 / VP-TOP-001 violation

- **Severity:** Low (cosmetic/display-only; does not affect inference
  correctness — the full 200-image bit-exact regression, C1/C2/C3/C4/C5/C6/C7,
  passes with 0 mismatches; only the LED digit display's transient
  power-on/reset value is affected).
- **Requirement violated:** REQ-030 ("led[11:0] held at 0 ... during and
  immediately after reset") and its VP item VP-TOP-001 ("`led[11:0] == 0`
  ... throughout reset").
- **Also contradicts:** `arch/arch.md` §4 BLK-010's own documented claim:
  "Reset behaviour: `led_r <= 11'd0` ... -> `led[11:0]==12'h000` during
  reset, satisfying REQ-030." The RTL as written does not match this
  documented behaviour — arch.md describes a single `led_r[9:0]` reset to
  all-zero, but `rtl/led_ctrl.v` actually resets two SEPARATE registers
  (`pred_r<=4'd0`, `verdict_r<=2'd0`) whose COMBINATIONAL recombination does
  not evaluate to all-zero.

### Root cause (rtl/led_ctrl.v)

```verilog
always @(posedge clk) begin
    if (!rst_n) begin
        pred_r         <= 4'd0;
        verdict_r      <= 2'd0;      // 2'd0 = CORRECT, NOT 2'd2 = TRASH
        ...
    end ...
end

wire [9:0] led_digit = (verdict_r == 2'd2) ? 10'd0 : (10'd1 << pred_r);
...
assign led = {led_blink, led_fail, led_digit};
```

`verdict_r` resets to `2'd0` (the CORRECT encoding), not `2'd2` (TRASH, the
only encoding that forces `led_digit` to all-zero). Combined with
`pred_r<=4'd0`, `led_digit` evaluates to `10'd1 << 0 = 10'b00_0000_0001`
— i.e. **`led[0]` reads 1** for the entire reset-asserted window (and
continues to read 1 after reset release, until the very first `lc_present`
pulse ~50,986 clk cycles later at the sim pacing used — real hardware:
~510 us at the default 100 MHz/CLK_DIV=868 pacing — overwrites it with the
first real result). `led[11]` (blink) and `led[10]` (fail flag) are correctly
0 during this window; only `led[9:0]`'s bit 0 is wrong.

### Reproduction (deterministic, TB-side only — no RTL modified)

```
$ cd mnist_npu
$ iverilog -g2005 -Wall -I. -o /tmp/tb_reset.vvp verify/tests/tb_reset.v -f filelist.f
$ vvp /tmp/tb_reset.vvp
FAIL TOP-001: led==0 throughout reset: got=0x00000001 want=0x00000000 @6000
FAIL TOP-001: led==0 throughout reset: got=0x00000001 want=0x00000000 @16000
... (20 total, one per checked reset cycle)
FAIL tb_reset: 20 errors
```

`uart_tx` idle-high and the post-release `img_idx==0`/first-state checks in
the same test PASS — only the `led[9:0]==0` condition fails, and only bit 0.

### Expected vs actual

| Signal | Expected (REQ-030 / arch.md) | Actual (RTL as committed) |
|---|---|---|
| `led[11:0]` during reset | `12'h000` | `12'h001` |
| `led[11]` (blink) | 0 | 0 (correct) |
| `led[10]` (fail flag) | 0 | 0 (correct) |
| `led[9:0]` (digit) | `10'b00_0000_0000` | `10'b00_0000_0001` |

### Suggested fix direction (NOT applied — rtl/ is frozen)

Reset `verdict_r` to `2'd2` (TRASH) instead of `2'd0`, so `led_digit`
combinationally forces to all-zero on reset (matching the same encoding the
design already uses for the steady-state TRASH case) — the minimal one-line
change consistent with arch.md's stated intent. Left for the architect/fe-rtl
owner since RTL is frozen for this verification pass.

## No other findings

All other checks (C1–C7, VP-TOP-001..008, VP-LED-001..003, VP-MAC-001..003,
VP-LUT-001/002, VP-ROM-001, VP-UART-001/002, VP-CTRL-001/002) pass. See
`verify/report.txt` for the full evidence summary.

## RESOLUTION (2026-08-25) — FIXED in rtl/led_ctrl.v, re-verified in run-002

Fix applied (Rinri-approved un-freeze, in-session on deepseek-v4-flash):

    assign led = (!rst_n) ? 12'd0 : {led_blink, led_fail, led_digit};

Deliberately NOT the originally suggested one-liner (verdict_r reset to 2'd2):
that encoding would flip `led_fail = (verdict_r != 2'd0)` high, putting
led[10]=1 during reset — merely moving the REQ-030 violation from led[0] to
led[10]. The output-level reset override is the exact minimal fix and matches
arch.md BLK-010's documented "led[11:0]==12'h000 during reset".

Re-verification evidence (verify/run-002/):
- tb_reset: PASS (was FAIL 20 errors in run-001)
- Full iverilog regression: PASS=9 FAIL=0 ERROR=0 (incl. 200/200 UART lines
  byte-exact vs golden, check_lut 65536/65536)
- cocotb independent harness: PASS (run-002/cocotb_stage2)
- REQ-030: now fully closed (both halves: uart_tx idle-high + led[11:0]==0)
