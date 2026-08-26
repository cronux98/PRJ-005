#---------------------------------------------------------------------
# test_cnn_soc.py — firmware-driven co-sim scoreboard (fe-firmware P4)
#
# Observes cnn_soc booting the committed POST firmware (bootrom bake,
# sw/firmware.hex, md5 dd61138d). Grounded in arch.md §7.3 register map,
# post_fw.c scoreboard hooks, and the frozen golden data:
#
#   UART stream (byte-exact, REQ-024):
#     "POST cnn_soc v1\n"                      (header; leading 'P' = the
#                                               bit-time calibration char,
#                                               fe-firmware skill convention)
#     "P"                                      (test_uart's TX probe byte)
#     "IMG 000: This is number 7 | confidence 94% | expected 7 | CORRECT\n"
#                                              (golden line, expected_outputs.txt:1)
#     "POST nper=6 fails=0\n"                  (POST summary)
#
#   SRAM results table (post_fw.c, word index = addr[16:2]):
#     mem[0x4000] = 0x504F5354 magic 'POST'
#     mem[0x4001] = 6         nper
#     mem[0x4002] = 0         fails
#     mem[0x4003..0x4008] = 0 flags[6] (0=PASS 1=FAIL)
#     mem[0x4009] = 0xA5A5A5A5 done marker (wd-flag slot; no WDT in cnn_soc)
#
#   LED (REQ-026): final = one-hot pred [9:0] (1<<7 = 0x080), [10] fail=0,
#   [11] busy=0. u_picorv32.trap must never assert (G5).
#
# UART decode: self-calibrate bit time from the leading 'P' (0x50 → LSB
# 0,0,0,0,1 → start + 4 zero bits = 5 leading low periods → first rising
# edge at 5 bit-times), ride out the rest of the first frame, then decode
# each following char by mid-bit sampling at 1.5..8.5 bit-times. Stop after
# len(EXPECTED) chars. CLK_DIV=4 (sim override, arch.md §6.5) → bit=40 ns.
#---------------------------------------------------------------------
import cocotb
from cocotb.triggers import Timer, RisingEdge, FallingEdge
from cocotb.utils import get_sim_time
from cocotb.clock import Clock

# Byte-exact expected UART stream (grounded in post_fw.c + expected_outputs.txt:1)
EXPECTED_STREAM = (
    b"POST cnn_soc v1\n"
    b"P"
    b"IMG 000: This is number 7 | confidence 94% | expected 7 | CORRECT\n"
    b"POST nper=6 fails=0\n"
)

# SRAM results table word indices (addr[16:2])
MAGIC_W = 0x4000
NPER_W  = 0x4001
FAILS_W = 0x4002
FLAGS_W = 0x4003          # 6 consecutive words
DONE_W  = 0x4009

MAGIC   = 0x504F5354      # 'POST'
DONE    = 0xA5A5A5A5

CLK_PER = 10              # ns, 100 MHz (CLK-001)


async def uart_monitor(dut, stream, expected_len):
    """Decode the UART byte stream; append bytes to `stream`."""
    rx = dut.uart_tx

    # 1. leading start bit: first falling edge
    await FallingEdge(rx)
    t_fall = get_sim_time("ns")

    # 2. first rising edge; 'P' (0x50) has 5 leading low periods
    #    (start bit + 4 zero data bits), so the bit time is 1/5 of the
    #    low-run length.
    await RisingEdge(rx)
    t_rise = get_sim_time("ns")
    bit_ns = (t_rise - t_fall) / 5.0
    n_low = round((t_rise - t_fall) / bit_ns)   # = 5 for 'P'

    # 3. decode the first char: data bits 0..n_low-2 are the leading ZEROS
    #    already consumed by calibration; sample the remaining bits
    #    n_low-1..7 at t_rise + (0.5 + k)*bit.
    byte = 0
    now = t_rise
    for k in range(8 - n_low + 1):
        target = t_rise + (0.5 + k) * bit_ns
        await Timer(target - now, unit="ns")
        if int(rx.value):
            byte |= (1 << (n_low - 1 + k))
        now = target
    stream.append(byte)

    # 4. ride out the rest of the first frame (end at t_fall + 10*bit)
    await Timer(t_fall + 10.0 * bit_ns - now, unit="ns")

    # 5. decode remaining chars; stop at expected_len (firmware halts after)
    while len(stream) < expected_len:
        await FallingEdge(rx)
        t0 = get_sim_time("ns")
        now = t0
        byte = 0
        for i in range(8):
            target = t0 + (1.5 + i) * bit_ns
            await Timer(target - now, unit="ns")
            if int(rx.value):
                byte |= (1 << i)
            now = target
        stream.append(byte)
        await Timer(t0 + 10.0 * bit_ns - now, unit="ns")


def sram_word(dut, idx):
    """Read a 32-bit SRAM word; return None while it still contains X/Z
    (the SRAM is not reset-initialised — un-written words are all-X until
    the firmware stores to them, arch.md §4 BLK-004)."""
    try:
        return dut.u_sram.mem[idx].value.to_unsigned()
    except ValueError:
        return None


async def wait_done(dut, deadline_ns):
    """Poll the SRAM done marker until it appears or the deadline passes."""
    while get_sim_time("ns") < deadline_ns:
        if sram_word(dut, DONE_W) == DONE:
            return True
        await Timer(2000, unit="ns")
    return False


@cocotb.test(timeout_time=50, timeout_unit="ms")
async def test_firmware_post(dut):
    """Boot the committed firmware, verify UART + SRAM + LED + trap."""
    cocotb.start_soon(Clock(dut.clk, CLK_PER, unit="ns").start())

    # Reset: assert >= 20 cycles (ASM-001 min 2; TB asserts >= 10)
    dut.rst_n.value = 0
    for _ in range(20):
        await RisingEdge(dut.clk)
    dut.rst_n.value = 1

    # UART decoder runs concurrently with the SRAM poll
    stream = []
    cocotb.start_soon(uart_monitor(dut, stream, len(EXPECTED_STREAM)))

    # 1. SRAM results table: done marker, then full table check
    #    (walk = image copy + 667,208-cycle inference + UART: ~6.7 ms sim)
    assert await wait_done(dut, 40_000_000), "SRAM done marker never appeared"
    assert sram_word(dut, MAGIC_W) == MAGIC, \
        f"magic mismatch: 0x{sram_word(dut, MAGIC_W):08x}"
    assert sram_word(dut, NPER_W) == 6, \
        f"nper mismatch: {sram_word(dut, NPER_W)}"
    assert sram_word(dut, FAILS_W) == 0, \
        f"fails mismatch: {sram_word(dut, FAILS_W)}"
    for i in range(6):
        v = sram_word(dut, FLAGS_W + i)
        assert v == 0, f"flag[{i}] = {v} (expect 0=PASS)"

    # 2. UART stream: byte-exact golden (REQ-024)
    for _ in range(20000):
        if len(stream) >= len(EXPECTED_STREAM):
            break
        await Timer(1000, unit="ns")
    got = bytes(stream)
    assert len(got) == len(EXPECTED_STREAM), \
        f"UART short: got {len(got)} bytes, want {len(EXPECTED_STREAM)}"
    assert got == EXPECTED_STREAM, (
        f"UART mismatch:\n got: {got!r}\nwant: {EXPECTED_STREAM!r}"
    )

    # 3. LED final pattern (REQ-026): one-hot pred 7, no fail/busy bits
    await Timer(2000, unit="ns")
    led = dut.led.value.to_unsigned()
    assert led == 0x080, f"LED = 0x{led:03x} (expect 0x080 = 1<<7)"

    # 4. CPU trap must never assert (G5)
    assert int(dut.u_picorv32.trap.value) == 0, "picorv32 trap asserted"

    dut._log.info("SCOREBOARD PASS: UART golden line byte-exact, SRAM 6/6 PASS, "
                  f"fails=0, LED 0x{led:03x}, trap clean")
