"""
test_mnist_top.py -- Stage 2 (fe-cocotb) INDEPENDENT harness for cnn_npu.

Independently re-verifies (per the verify task's Stage 2 scope):
  - UART framing (start bit, 8 data bits LSB-first, stop bit, byte widths)
  - the exact UART line strings, diffed against the frozen golden
    arch/golden_model/expected_outputs.txt
  - LED[11] busy-blink-window timing (>=2 transitions while busy;
    constant while held)
  - verdict/LED[10] exclusivity (led[10] == (verdict != CORRECT))

Separate implementation from Stage 1's Verilog tb_common/uart_monitor.vh
(different language/control flow) — a bug in one is unlikely in the other.

CNN-specific: state encoding is ST_CONV1=0..ST_PRESENT=6, ST_HOLD=7;
confidence/verdict registers are stable by ST_HOLD, so the main loop breaks
there (same constant value as the v1 test's ST_RESULT breakpoint). The CNN
free-runs images 0..99 in order (img_idx is a counter; there is NO
image-select mechanism), so IMG_LIST is the first 19 sequential results
0..18 — ending with the trash case at index 18 (CNN trash set: 18, 73;
v1's image 8 is CORRECT in the CNN golden).

Run via verify/scripts/run_cocotb_stage2.sh (wraps the fe-cocotb skill's
run_cocotb.sh with this project's filelist/toplevel/outdir).
"""
import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

CLK_DIV = 4
CLK_PERIOD_NS = 10
IMG_LIST = list(range(19))   # 0..18 sequential; 18 is TRASH
N_IMAGES = len(IMG_LIST)

ROOT = "/home/smdadmin/PRJ-005/cnn"
GOLDEN_LINES_PATH = os.path.join(ROOT, "arch/golden_model/expected_outputs.txt")

ST_RESULT = 7    # CNN: ST_HOLD — result regs (best_idx/confidence/verdict) stable
ST_HOLD = 7


async def reset(dut):
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def uart_read_byte(dut, clkdiv):
    """Independent bit-level UART decoder: polls dut.uart_tx via RisingEdge only."""
    while True:
        await RisingEdge(dut.clk)
        if int(dut.uart_tx.value) == 0:
            break
    for ci in range(clkdiv - 1):
        await RisingEdge(dut.clk)
        assert int(dut.uart_tx.value) == 0, f"start bit width violation cycle {ci+1}/{clkdiv}"

    data = 0
    for bit in range(8):
        await RisingEdge(dut.clk)
        bitval = int(dut.uart_tx.value)
        data |= (bitval << bit)
        for ci in range(clkdiv - 1):
            await RisingEdge(dut.clk)
            assert int(dut.uart_tx.value) == bitval, f"data bit {bit} width violation cycle {ci+1}/{clkdiv}"

    for ci in range(clkdiv):
        await RisingEdge(dut.clk)
        assert int(dut.uart_tx.value) == 1, f"stop bit width violation cycle {ci}/{clkdiv}"

    return data


async def uart_read_line(dut, clkdiv):
    bs = bytearray()
    while True:
        b = await uart_read_byte(dut, clkdiv)
        bs.append(b)
        if b == 0x0A:
            break
    return bs.decode("ascii")


async def hold_window_monitor(dut, ctrl, violations):
    """Runs concurrently: whenever state==ST_HOLD, led[11] must stay constant
    (REQ 'steady off once presented'). Independent of the main coroutine."""
    prev_state = int(ctrl.state.value)
    held_val = None
    while True:
        await RisingEdge(dut.clk)
        st = int(ctrl.state.value)
        if st == ST_HOLD:
            cur = (int(dut.led.value) >> 11) & 1
            if prev_state != ST_HOLD:
                held_val = cur
            elif cur != held_val:
                violations.append(f"led[11] changed {held_val}->{cur} mid-HOLD at t={cocotb.utils.get_sim_time('ns')}")
        prev_state = st


@cocotb.test()
async def test_mnist_uart_led(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, units="ns").start())
    await reset(dut)

    with open(GOLDEN_LINES_PATH) as f:
        golden_lines = f.readlines()          # line i == image i's UART line

    ctrl = dut.dut.u_ctrl_fsm

    hold_violations = []
    cocotb.start_soon(hold_window_monitor(dut, ctrl, hold_violations))

    for img in range(N_IMAGES):
        image = IMG_LIST[img]

        # ---- 1. busy-window blink-transition count ----
        prev_led11 = (int(dut.led.value) >> 11) & 1
        toggle_count = 0
        while True:
            await RisingEdge(dut.clk)
            led11 = (int(dut.led.value) >> 11) & 1
            if led11 != prev_led11:
                toggle_count += 1
            prev_led11 = led11
            if int(ctrl.lc_present.value):
                break
        assert toggle_count >= 2, f"image {image}: only {toggle_count} led[11] transitions during busy window"

        pred = int(ctrl.best_idx.value)
        conf = int(ctrl.confidence.value)
        verdict = int(ctrl.verdict.value)
        idx = int(ctrl.img_idx.value)
        assert idx == image, f"img_idx mismatch: got {idx} want {image}"

        # ---- 2. verdict/LED[10] exclusivity + LED[9:0] one-hot/trash-off ----
        await RisingEdge(dut.clk)   # into next compute; led still latched
        led10 = (int(dut.led.value) >> 10) & 1
        expected_led10 = 1 if verdict != 0 else 0
        assert led10 == expected_led10, (
            f"image {image}: led[10]={led10} but verdict={verdict} (want {expected_led10})"
        )
        led09 = int(dut.led.value) & 0x3FF
        expected_digit = 0 if verdict == 2 else (1 << pred)
        assert led09 == expected_digit, f"image {image}: led[9:0]={led09:#x} want {expected_digit:#x}"

        # ---- 3. independent UART line decode vs golden ----
        line = await uart_read_line(dut, CLK_DIV)
        golden = golden_lines[image]
        assert line == golden, f"image {image}: UART line mismatch\n got: {line!r}\nwant: {golden!r}"

        dut._log.info(
            f"image {image}: OK pred={pred} conf={conf}% verdict={verdict} "
            f"blink_toggles={toggle_count} line={line.strip()!r}"
        )

    await ClockCycles(dut.clk, 20)
    assert not hold_violations, f"HOLD-window led[11] violations: {hold_violations}"

    dut._log.info(
        f"PASS: {N_IMAGES} images independently re-verified "
        f"(UART framing+lines, LED[11] blink timing, LED[10]/LED[9:0]/verdict exclusivity, "
        f"HOLD-window led[11] constancy)"
    )
