//---------------------------------------------------------------------
// Module      : cnn_axi_slave
// Project     : cnn_soc                Technology : FPGA-generic (NOT Sky130 — spec.md §2.1)
// Traces      : REQ-012, REQ-016, REQ-017, REQ-018, REQ-019, REQ-020, REQ-021,
//               REQ-030, BLK-009
// Description : MMIO shell + single-shot sequencer around cnn_infer
//               (PLAN.md §6.2). Registers CNN_CTRL/STATUS/RESULT/EXP (§7.3),
//               784-byte image-buffer write path with per-lane wstrb packing
//               (REQ-020), start/done handshake, PARK abort, result latch on
//               lc_present.
//               - FSM-002 accept pattern (arch.md §6.2): register reads
//                 accept+2; register writes applied at the accept edge.
//               - FSM-003 sequencer (arch.md §6.3): ST_PARK/ST_RUN/ST_DONE,
//                 reset = ST_PARK; core parked by combinational
//                 core_rst_n = !(seq_park || park_reg).
//               - CNN_IMG word writes are serialised into 4 byte-writes on
//                 the single 8-bit image_buffer write port (drain counter);
//                 a subsequent CNN_IMG write is not accepted until the drain
//                 completes (awready backpressure; adapter holds the request).
//               Register-target writes update on ANY write to their offset
//               regardless of wstrb (PWDATA supplies the bits); CNN_IMG
//               honours wstrb lane-by-lane (§7.3 policy).
//               NOTE: authored directly by the fe-rtl orchestrator (provider
//               session-limit fallback, AGENTS.md precedent 2026-08-20);
//               contract = arch.md §4 BLK-009 + §6.2 + §6.3 + §7.3 verbatim.
// Clock/Reset : clk (CD_CORE, 100 MHz) / rst_n (fully SYNCHRONOUS active-low — no async)
// Assumptions : START-while-BUSY / START-while-PARK ignored (REQ-016); PARK
//               write aborts (partial results discarded); lc_present is
//               exactly 1 cycle (cnn/arch/arch.md:427-434) and result
//               registers hold until the next START. img_we is deasserted
//               under reset and whenever the drain is idle (image_buffer
//               contents are CPU-owned, MEM-004).
// Source      : custom
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none

module cnn_axi_slave (
    input  wire         clk,        // core clock (CD_CORE, 100 MHz)
    input  wire         rst_n,      // fully synchronous active-low reset
    // IFI-003 slave (cnn_ prefix)
    input  wire         cnn_awvalid,
    output reg          cnn_awready,
    input  wire [31:0]  cnn_awaddr,
    input  wire [2:0]   cnn_awprot,
    input  wire         cnn_wvalid,
    output reg          cnn_wready,
    input  wire [31:0]  cnn_wdata,
    input  wire [3:0]   cnn_wstrb,
    output reg          cnn_bvalid,
    input  wire         cnn_bready,
    input  wire         cnn_arvalid,
    output reg          cnn_arready,
    input  wire [31:0]  cnn_araddr,
    input  wire [2:0]   cnn_arprot,
    output reg          cnn_rvalid,
    input  wire         cnn_rready,
    output reg  [31:0]  cnn_rdata,
    // IFI-001 to cnn_infer (BLK-010)
    output wire         core_rst_n,   // combinational !(seq_park || park_reg)
    output wire [3:0]   exp_label,    // CNN_EXP register
    output reg  [9:0]   img_waddr,    // image-buffer CPU write address
    output reg  [7:0]   img_wdata,    // image-buffer CPU write data
    output reg          img_we,       // image-buffer CPU write enable
    input  wire [3:0]   pred,         // lf_pred
    input  wire [6:0]   conf,         // lf_conf
    input  wire [1:0]   verdict,      // lf_verdict
    input  wire         busy,         // lc_busy (not used by the sequencer; exposed via STATUS path through busy_r)
    input  wire         present       // lc_present, exactly 1 cycle
);

    // FSM-002 : axil_slave_accept (arch.md §6.2) — 3 states, reset = ST_IDLE
    // | State       | Condition                | Next state  | Registered actions this cycle        |
    // | ST_IDLE     | awvalid && wvalid (&& !img-drain busy) | ST_WRESP | accept; write applied at this edge |
    // | ST_IDLE     | arvalid                  | ST_RRESP    | accept (arready<=1); addr_r<=araddr  |
    // | ST_IDLE     | else                     | ST_IDLE     | —                                    |
    // | ST_WRESP    | always                   | ST_IDLE     | bvalid<=1 (exactly 1 cycle)          |
    // | ST_RRESP    | always                   | ST_RRESP_DLY| rd_r<=decode(addr_r)                 |
    // | ST_RRESP_DLY| always                   | ST_IDLE     | rvalid<=1; rdata<=rd_r (1 cycle)     |
    // | (other)     | default:                 | ST_IDLE     | illegal-state recovery               |
    localparam [1:0] ST_IDLE      = 2'd0;
    localparam [1:0] ST_WRESP     = 2'd1;
    localparam [1:0] ST_RRESP     = 2'd2;
    localparam [1:0] ST_RRESP_DLY = 2'd3;

    reg [1:0]  state;
    reg [11:0] addr_r;       // captured read address (low 12 bits)
    reg [31:0] rd_r;         // registered register-read result
    reg [31:0] rd_decode;    // combinational register-read decode (Block 1 samples it)

    // Register file (§7.3). CNN_CTRL[1] PARK is also the sequencer's park_reg.
    reg        park_reg;     // CNN_CTRL[1]
    reg [3:0]  exp_r;        // CNN_EXP[3:0]

    // Image-buffer write serialiser (single 8-bit write port, MEM-004).
    reg [31:0] wdata_r;      // captured word
    reg [3:0]  wstrb_r;      // captured lane enables
    reg [9:0]  woff_r;       // captured word-aligned byte offset
    reg        drain;        // drain in progress (buffer port busy)
    reg [1:0]  dr_cnt;       // lane counter 1..3 (lane 0 emitted at accept)
    // img_waddr / img_wdata / img_we are output reg ports (declared in the
    // port list only — driven procedurally by the FSM-002 block below).

    // FSM-003 : single-shot sequencer (arch.md §6.3) — 3 states, reset = ST_PARK
    // | State  | Condition               | Next state | Registered actions this cycle          |
    // | ST_PARK| park_write              | ST_PARK    | (park_reg<=1 via regfile; stay parked) |
    // | ST_PARK| start_strobe && !park_reg | ST_RUN   | busy_r<=1; done_r<=0; seq_park<=0      |
    // | ST_PARK| else                    | ST_PARK    | done_r<=0                              |
    // | ST_RUN | park_write              | ST_PARK    | abort: busy_r<=0; done_r<=0; seq_park<=1|
    // | ST_RUN | present                 | ST_DONE    | latch result_r; done_r<=1; busy_r<=0; seq_park<=1 |
    // | ST_RUN | else                    | ST_RUN     | start ignored while BUSY               |
    // | ST_DONE| park_write              | ST_PARK    | busy_r<=0; done_r<=0; seq_park<=1      |
    // | ST_DONE| start_strobe && !park_reg | ST_RUN   | done_r<=0; busy_r<=1; seq_park<=0      |
    // | ST_DONE| else                    | ST_DONE    | done_r held 1                          |
    // | (other)| default:                | ST_PARK    | illegal-state recovery                 |
    localparam [1:0] ST_PARK = 2'd0;
    localparam [1:0] ST_RUN  = 2'd1;
    localparam [1:0] ST_DONE = 2'd2;

    reg [1:0]  seq_state;
    reg        busy_r;       // CNN_STATUS[0]
    reg        done_r;       // CNN_STATUS[1]
    reg        seq_park;     // sequencer park output
    reg [31:0] result_r;     // CNN_RESULT latch

    // Combinational decode helpers.
    wire is_img_w = (cnn_awaddr[11:0] >= 12'h100) && (cnn_awaddr[11:0] <= 12'h40F);
    wire [9:0] p     = cnn_awaddr[11:0] - 12'h100;      // CNN_IMG byte offset
    wire [9:0] woff  = {p[9:2], 2'b00};                 // word-aligned byte offset

    // Sequencer input events (derived from the FSM-002 write accept of
    // CNN_CTRL, evaluated combinationally during the accept cycle —
    // arch.md §6.3 edge semantics).
    wire wr_ctrl     = (state == ST_IDLE) && cnn_awvalid && cnn_wvalid &&
                       (cnn_awaddr[11:0] == 12'h000);
    wire start_strobe = wr_ctrl && cnn_wstrb[0] && cnn_wdata[0];
    wire park_write   = wr_ctrl && cnn_wdata[1];

    // Combinational core reset (park mechanism, arch.md §9): never async.
    assign core_rst_n = !(seq_park || park_reg);
    assign exp_label  = exp_r[3:0];

    // ------------------------------------------------------------------
    // Block 1: FSM-002 accept/response + register file + IMG drain.
    // (IMG drain chain first so the accept-edge lane-0 emit wins on the
    //  accept edge; drain is 0 there by the awready gating.)
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            addr_r      <= 12'd0;
            rd_r        <= 32'd0;
            park_reg    <= 1'b0;
            exp_r       <= 4'd0;
            wdata_r     <= 32'd0;
            wstrb_r     <= 4'd0;
            woff_r      <= 10'd0;
            drain       <= 1'b0;
            dr_cnt      <= 2'd0;
            img_waddr   <= 10'd0;
            img_wdata   <= 8'd0;
            img_we      <= 1'b0;
            cnn_awready <= 1'b0;
            cnn_wready  <= 1'b0;
            cnn_arready <= 1'b0;
            cnn_bvalid  <= 1'b0;
            cnn_rvalid  <= 1'b0;
            cnn_rdata   <= 32'd0;
        end else begin
            // Drain chain: emit one byte lane per cycle while draining.
            if (drain) begin
                img_waddr <= woff_r + {8'd0, dr_cnt};
                img_wdata <= wdata_r[8*dr_cnt +: 8];
                img_we    <= wstrb_r[dr_cnt];
                if (dr_cnt == 2'd3) drain <= 1'b0;
                else                dr_cnt <= dr_cnt + 2'd1;
            end else begin
                img_we <= 1'b0;
            end

            // Default deassertions (no latches).
            cnn_awready <= 1'b0;
            cnn_wready  <= 1'b0;
            cnn_arready <= 1'b0;
            cnn_bvalid  <= 1'b0;
            cnn_rvalid  <= 1'b0;

            case (state)
                ST_IDLE: begin
                    // Write request: accept (for CNN_IMG only when the buffer
                    // drain has finished) and apply the write at this edge.
                    if (cnn_awvalid && cnn_wvalid && (!is_img_w || !drain)) begin
                        cnn_awready <= 1'b1;
                        cnn_wready  <= 1'b1;
                        if (cnn_awaddr[11:0] == 12'h000) begin
                            // CNN_CTRL: any write updates PARK from PWDATA[1]
                            // (register policy, §7.3); START is a strobe
                            // evaluated by the sequencer (start_strobe).
                            park_reg <= cnn_wdata[1];
                        end else if (cnn_awaddr[11:0] == 12'h00C) begin
                            // CNN_EXP: any write updates [3:0].
                            exp_r <= cnn_wdata[3:0];
                        end else if (is_img_w) begin
                            // CNN_IMG: capture the word; emit lane 0 now,
                            // lanes 1..3 via the drain chain.
                            wdata_r   <= cnn_wdata;
                            wstrb_r   <= cnn_wstrb;
                            woff_r    <= woff;
                            drain     <= 1'b1;
                            dr_cnt    <= 2'd1;
                            img_waddr <= woff;
                            img_wdata <= cnn_wdata[7:0];
                            img_we    <= cnn_wstrb[0];
                        end
                        // 0x04/0x08/0x0C-read/other offsets: write ignored,
                        // handshake still completes.
                        state <= ST_WRESP;
                    end else if (cnn_arvalid) begin
                        // Read request: accept and capture the address.
                        cnn_arready <= 1'b1;
                        addr_r      <= cnn_araddr[11:0];
                        state       <= ST_RRESP;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                ST_WRESP: begin
                    // 1-cycle write response (no BRESP); no bready wait.
                    cnn_bvalid <= 1'b1;
                    state      <= ST_IDLE;
                end

                ST_RRESP: begin
                    // Register-read decode registered at this edge (FSM-002).
                    rd_r  <= rd_decode;
                    state <= ST_RRESP_DLY;
                end

                ST_RRESP_DLY: begin
                    // 1-cycle read response (no RRESP); rdata stable.
                    cnn_rvalid <= 1'b1;
                    cnn_rdata  <= rd_r;
                    state      <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    // Combinational register-read decode on the captured address (§7.3).
    // CNN_CTRL: {30'b0, park, 1'b0}; CNN_STATUS: {30'b0, done, busy};
    // CNN_RESULT: result_r; CNN_EXP / CNN_IMG / other offsets: 0.
    always @* begin
        case (addr_r[11:0])
            12'h000: rd_decode = {30'b0, park_reg, 1'b0};
            12'h004: rd_decode = {30'b0, done_r,   busy_r};
            12'h008: rd_decode = result_r;
            default: rd_decode = 32'd0;
        endcase
    end

    // ------------------------------------------------------------------
    // Block 2: FSM-003 single-shot sequencer. Reads start_strobe /
    // park_write / park_reg / present; drives busy_r/done_r/seq_park/
    // result_r only (single driver each).
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            seq_state <= ST_PARK;
            busy_r    <= 1'b0;
            done_r    <= 1'b0;
            seq_park  <= 1'b1;
            result_r  <= 32'd0;
        end else begin
            case (seq_state)
                ST_PARK: begin
                    if (park_write) begin
                        // PARK write while parked: stay parked (redundant).
                        busy_r   <= 1'b0;
                        done_r   <= 1'b0;
                        seq_park <= 1'b1;
                        seq_state <= ST_PARK;
                    end else if (start_strobe && !park_reg) begin
                        // Launch: core unparked next cycle.
                        busy_r    <= 1'b1;
                        done_r    <= 1'b0;
                        seq_park  <= 1'b0;
                        seq_state <= ST_RUN;
                    end else begin
                        busy_r   <= 1'b0;
                        done_r   <= 1'b0;
                        seq_park <= 1'b1;
                        seq_state <= ST_PARK;
                    end
                end

                ST_RUN: begin
                    if (park_write) begin
                        // Abort: core held in reset, partial results discarded.
                        busy_r   <= 1'b0;
                        done_r   <= 1'b0;
                        seq_park <= 1'b1;
                        seq_state <= ST_PARK;
                    end else if (present) begin
                        // Result latch on the present edge; re-park lands 1
                        // cycle after the present cycle (<= 2-cycle REQ-021
                        // bound).
                        result_r  <= {14'b0, verdict, 1'b0, conf, 4'b0, pred};
                        busy_r    <= 1'b0;
                        done_r    <= 1'b1;
                        seq_park  <= 1'b1;
                        seq_state <= ST_DONE;
                    end else begin
                        // START ignored while BUSY (REQ-016); park_reg<=0
                        // writes have no effect here.
                        busy_r   <= 1'b1;
                        done_r   <= 1'b0;
                        seq_park <= 1'b0;
                        seq_state <= ST_RUN;
                    end
                end

                ST_DONE: begin
                    if (park_write) begin
                        busy_r   <= 1'b0;
                        done_r   <= 1'b0;
                        seq_park <= 1'b1;
                        seq_state <= ST_PARK;
                    end else if (start_strobe && !park_reg) begin
                        // DONE cleared on next START (REQ-017).
                        busy_r    <= 1'b1;
                        done_r    <= 1'b0;
                        seq_park  <= 1'b0;
                        seq_state <= ST_RUN;
                    end else begin
                        busy_r   <= 1'b0;
                        done_r   <= 1'b1;   // held
                        seq_park <= 1'b1;
                        seq_state <= ST_DONE;
                    end
                end

                default: begin
                    // Illegal-state recovery.
                    busy_r    <= 1'b0;
                    done_r    <= 1'b0;
                    seq_park  <= 1'b1;
                    seq_state <= ST_PARK;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
