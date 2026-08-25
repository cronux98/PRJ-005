//---------------------------------------------------------------------
// Module      : apb_regs
// Project     : rinriAI   Technology : Sky130 130 nm
// Traces      : REQ-006, REQ-009, REQ-010, REQ-013, REQ-017, REQ-020
// Description : APB4 zero-wait slave. Decodes the register map (arch.md
//               section 7), generates 1-cycle control strobes, bridges
//               CSR weight accesses (WADDR/WDATA auto-increment) to
//               weight_ram port B, gates init_weights on !busy, and
//               assembles STATUS. No FSM: decode is combinational.
// Clock/Reset : clk_core (CD_CORE) / rst_n (synchronous, active low)
// Assumptions : Single clock domain; all inputs synchronous to clk_core.
//               Port B arbitration (init_walk vs CSR) lives in weight_ram;
//               here we only drop the CSR b_we while init_busy.
// Source      : custom (no external IP)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none                 // typo'd implicit wires become errors

module apb_regs (
    input  wire        clk_core,      // core clock (CD_CORE, 50 MHz)
    input  wire        rst_n,         // synchronous active-low reset (ASM-002)

    // APB4 slave (IF-001) ----------------------------------------------
    input  wire        psel,          // slave select
    input  wire        penable,       // access phase qualifier
    input  wire        pwrite,        // 1 = write, 0 = read
    input  wire [31:0] paddr,         // byte address
    input  wire [31:0] pwdata,        // write data
    output reg  [31:0] prdata,        // read data (combinational mux)
    output wire        pready,        // zero-wait: high in access phase
    output wire        pslverr,       // high on unmapped address, no side effect

    // Learner control (IFI-001) ----------------------------------------
    output wire        start_p,       // 1-cycle start strobe
    output wire        step_p,        // 1-cycle step strobe
    output wire        halt_p,        // 1-cycle halt strobe
    output wire        freeze,        // level: 1 = inference-only
    output wire [3:0]  lr_shift,      // level: eta = 2^-lr_shift

    // Weight RAM port B / CSR bridge (IFI-005) -------------------------
    output wire [15:0] b_addr,        // port B address (= WADDR)
    output wire [15:0] b_wdata,       // port B write data (= WDATA[15:0])
    output wire        b_we,          // port B write enable (dropped if init_busy)
    input  wire [15:0] b_rdata,       // port B combinational read data
    output wire        init_go,       // bulk-init start (gated on !busy)
    output wire [15:0] init_val,      // bulk-init value (= W_INIT_VAL)
    input  wire        init_busy,     // bulk-init in progress

    // Stats (IFI-006) --------------------------------------------------
    input  wire [31:0] sample_count,  // saturating sample counter
    input  wire [31:0] correct_count, // saturating correct counter
    input  wire [31:0] error_count,   // saturating error counter
    input  wire        err,           // sticky malformed-sample flag
    input  wire [7:0]  pred,          // last predicted class
    output wire        clr_stats_p,   // 1-cycle clear-counters strobe

    // Learner status (IFI-009) -----------------------------------------
    input  wire        busy,          // learner run_active
    input  wire        done           // step/halt completed
);

    // Word-index of each mapped register (paddr[5:2]) ------------------
    localparam [3:0] A_CTRL    = 4'd0,   // 0x00
                     A_LRN     = 4'd1,   // 0x04
                     A_STATUS  = 4'd2,   // 0x08
                     A_SAMPLE  = 4'd3,   // 0x0C
                     A_CORRECT = 4'd4,   // 0x10
                     A_ERROR   = 4'd5,   // 0x14
                     A_PRED    = 4'd6,   // 0x18
                     A_WADDR   = 4'd7,   // 0x1C
                     A_WDATA   = 4'd8,   // 0x20
                     A_WINIT   = 4'd9;   // 0x24

    // Level/state registers (only stored bits; strobes are not stored) -
    reg        freeze_ff;                // CTRL[3], the frozen level
    reg  [3:0] lr_shift_ff;              // LRN_RATE[3:0], reset 8
    reg [15:0] waddr_ff;                 // WADDR pointer into weight RAM
    reg [15:0] winit_val_ff;             // W_INIT_VAL bulk-init constant

    // Address decode (combinational, window 0x00..0x24) ----------------
    // Mapped iff high bits zero, word-aligned, and index within 0..9.
    wire [3:0] word_sel    = paddr[5:2];                 // 4-aligned word index
    wire       addr_in_page = (paddr[31:6] == 26'd0);    // no aliasing above 0x3F
    wire       addr_aligned = (paddr[1:0] == 2'b00);     // APB word alignment
    wire       addr_mapped  = addr_in_page && addr_aligned && (word_sel <= A_WINIT);

    // APB phase qualifiers ---------------------------------------------
    wire       access_ph = psel && penable;              // ACCESS phase
    wire       access_wr = access_ph &&  pwrite;         // write access
    wire       access_rd = access_ph && !pwrite;         // read access

    assign pready  = access_ph;                          // zero-wait slave
    assign pslverr = access_ph && !addr_mapped;          // unmapped -> error, no side effect

    // Per-register selects ---------------------------------------------
    wire sel_ctrl  = addr_mapped && (word_sel == A_CTRL);
    wire sel_lrn   = addr_mapped && (word_sel == A_LRN);
    wire sel_waddr = addr_mapped && (word_sel == A_WADDR);
    wire sel_wdata = addr_mapped && (word_sel == A_WDATA);
    wire sel_winit = addr_mapped && (word_sel == A_WINIT);

    // CTRL write event (single-cycle in a zero-wait access phase) -------
    wire ctrl_wr = sel_ctrl && access_wr;

    // Control strobes: combinational from a CTRL write with the bit set.
    // The access phase is one cycle (pready always high), so each is a
    // clean 1-cycle pulse; they are never stored, so they read back 0.
    assign start_p     = ctrl_wr && pwdata[0];
    assign step_p      = ctrl_wr && pwdata[1];
    assign halt_p      = ctrl_wr && pwdata[2];
    assign clr_stats_p = ctrl_wr && pwdata[4];
    // init_weights gated on !busy: strobe ignored while the learner runs.
    assign init_go     = ctrl_wr && pwdata[5] && !busy;

    // Level outputs -----------------------------------------------------
    assign freeze   = freeze_ff;
    assign lr_shift = lr_shift_ff;
    assign init_val = winit_val_ff;

    // WDATA bridge to weight_ram port B (combinational) -----------------
    wire wdata_wr = sel_wdata && access_wr;              // WDATA write access
    wire wdata_rd = sel_wdata && access_rd;              // WDATA read access
    wire wdata_wr_commit = wdata_wr && !init_busy;       // real write only when idle
    // Increment WADDR after each committed write and after every read.
    wire wdata_incr = wdata_wr_commit || wdata_rd;

    assign b_addr  = waddr_ff;                           // read/write share the pointer
    assign b_wdata = pwdata[15:0];
    assign b_we    = wdata_wr_commit;                    // dropped while init_busy

    // Register file (sequential, synchronous reset per ASM-002) ---------
    always @(posedge clk_core) begin
        if (!rst_n) begin
            freeze_ff    <= 1'b0;                        // CTRL reset 0x0
            lr_shift_ff  <= 4'd8;                        // LRN_RATE reset 0x8
            waddr_ff     <= 16'h0000;                    // WADDR reset 0
            winit_val_ff <= 16'h0000;                    // W_INIT_VAL reset 0
        end else begin
            // CTRL[3] freeze level: only updated on a CTRL write.
            if (ctrl_wr) freeze_ff <= pwdata[3];

            // LRN_RATE[3:0] lr_shift level: only updated on a LRN_RATE write.
            if (sel_lrn && access_wr) lr_shift_ff <= pwdata[3:0];

            // WADDR: direct write sets the pointer; a WDATA access
            // auto-increments it. The two are mutually exclusive (one
            // address per transfer), so the priority is never exercised
            // both ways at once.
            if (sel_waddr && access_wr) waddr_ff <= pwdata[15:0];
            else if (wdata_incr)        waddr_ff <= waddr_ff + 16'd1;

            // W_INIT_VAL: bulk-init constant.
            if (sel_winit && access_wr) winit_val_ff <= pwdata[15:0];
        end
    end

    // Read data mux (combinational, default 0, latch-free) --------------
    // Unmapped addresses read 0 (and raise pslverr). Reserved bits read 0.
    // Strobe bits (CTRL[0,1,2,4,5]) read 0; CTRL[3] returns the freeze level.
    always @* begin
        prdata = 32'h00000000;                           // default: reserved/unmapped -> 0
        if (addr_mapped) begin
            case (word_sel)
                A_CTRL    : prdata = {28'h0000000, freeze_ff, 3'b000};   // only the freeze level reads back
                A_LRN     : prdata = {28'h0000000, lr_shift_ff};         // [3:0] lr_shift
                A_STATUS  : prdata = {28'h0000000, freeze_ff, err, done, busy}; // [3]frozen [2]err [1]done [0]busy
                A_SAMPLE  : prdata = sample_count;
                A_CORRECT : prdata = correct_count;
                A_ERROR   : prdata = error_count;
                A_PRED    : prdata = {24'h000000, pred};                 // [7:0] last pred
                A_WADDR   : prdata = {16'h0000, waddr_ff};               // [15:0] pointer
                A_WDATA   : prdata = {16'h0000, b_rdata};                // combinational port B read at WADDR
                A_WINIT   : prdata = {16'h0000, winit_val_ff};           // [15:0] init value
                default   : prdata = 32'h00000000;                       // illegal-index recovery
            endcase
        end
    end

endmodule

`default_nettype wire                 // restore default for downstream files
