//---------------------------------------------------------------------
// mnist_npu_cocotb_wrapper.v — Stage 2 (fe-cocotb) TB-side wrapper
// Purpose : cocotb's Makefile-based flow runs `make` from an arbitrary
//           OUTDIR (verify/run_cocotb/), so the mnist_npu leaf ROMs'
//           default $readmemh paths (relative to the mnist_npu project
//           root) would not resolve at simulation runtime. This wrapper
//           overrides them with ABSOLUTE paths instead, sidestepping
//           CWD entirely — TB-side only, not part of the frozen RTL
//           (mnist_npu.v itself is untouched, instantiated unmodified).
// Sim params: same small overrides used throughout verify/ (HOLD=8,
//           BLINK=4, CLK_DIV=4) so the busy-blink window and full-line
//           UART framing are both exercised within tractable cocotb
//           (Python/VPI) run time.
//---------------------------------------------------------------------
`timescale 1ns / 1ps

module mnist_npu_cocotb_wrapper (
    input  wire        clk,
    input  wire        rst_n,
    output wire [11:0] led,
    output wire        uart_tx
);
    mnist_npu #(
        .HOLD_CYCLES      (8),
        .BLINK_CYCLES     (4),
        .CLK_DIV          (4),
        .WEIGHTS_HEX_FILE ("/home/smdadmin/PRJ-005/mnist_npu/arch/golden_model/weights.hex"),
        .IMAGES_HEX_FILE  ("/home/smdadmin/PRJ-005/mnist_npu/arch/golden_model/images.hex"),
        .LABELS_HEX_FILE  ("/home/smdadmin/PRJ-005/mnist_npu/arch/golden_model/labels.hex"),
        .LUT_HEX_FILE     ("/home/smdadmin/PRJ-005/mnist_npu/rtl/sigmoid_lut.hex")
    ) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .led     (led),
        .uart_tx (uart_tx)
    );
endmodule
