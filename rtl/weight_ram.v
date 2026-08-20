//---------------------------------------------------------------------
// Module      : weight_ram
// Project     : rinriAI   Technology : Sky130 130 nm
// Traces      : REQ-006, REQ-013, REQ-020, REQ-021, REQ-022
// Description : W_TOT x 16-bit dual-port weight/bias memory (MEM-001).
//               Port A = learner datapath (BLK-004, IFI-004).
//               Port B = CSR (BLK-002, IFI-005) + bulk-init walk (FSM-003).
// Clock/Reset : clk_core (CD_CORE) / rst_n (synchronous, active low)
// Assumptions : Callers present only in-range addresses (0..W_TOT-1); the
//               weight address map (arch.md section 7) guarantees this.
//               A read and its dependent write are separated by >= 1 clock
//               by FSM-001 (arch.md section 6.1), so read-during-write is
//               never relied upon (see MEM WRITE comment below).
// Source      : custom (no external IP)
//---------------------------------------------------------------------
`timescale 1ns / 1ps
`default_nettype none                     // typo'd implicit wires become errors

module weight_ram #(
    // W_TOT: total stored words = FEATURES*HIDDEN + HIDDEN + HIDDEN*CLASSES
    //        + CLASSES. Default 784*32 + 32 + 32*10 + 10 = 25450 (REQ-022).
    //        Legal 1..65535, so W_TOT-1 always fits in W_A=16 bits.
    parameter integer W_TOT = 25450,
    // W_A: word-address width. Fixed at 16 for this design (guidelines section 8).
    parameter integer W_A   = 16
) (
    input  wire              clk_core,
    input  wire              rst_n,       // synchronous active-low (ASM-002)

    // Port A - learner datapath (IFI-004): combinational read, sync write
    input  wire [W_A-1:0]    a_addr,      // port A word address
    input  wire [15:0]       a_wdata,     // port A write data
    input  wire              a_we,        // port A write enable
    output wire [15:0]       a_rdata,     // port A combinational read data

    // Port B - CSR (IFI-005): combinational read, sync write, + bulk init
    input  wire [W_A-1:0]    b_addr,      // port B word address (WADDR)
    input  wire [15:0]       b_wdata,     // port B write data (WDATA[15:0])
    input  wire              b_we,        // port B write enable (CSR)
    output wire [15:0]       b_rdata,     // port B combinational read data
    input  wire              init_go,     // 1-cycle bulk-init start (gated on !busy in BLK-002)
    input  wire [15:0]       init_val,    // bulk-init fill value (W_INIT_VAL)
    output reg               init_busy    // level: bulk-init walk in progress
);

    // Last walk address as a W_A-bit constant. W_TOT <= 65535 (declared legal
    // range) and 2^W_A = 65536, so W_TOT-1 fits in W_A bits with no truncation.
    localparam [W_A-1:0] WALK_LAST = W_TOT - 1;

    // FSM-003 init_walk state encoding (binary, reset = IDLE; arch.md section 6.3)
    localparam ST_IDLE = 1'b0,
               ST_WALK = 1'b1;

    // MEM-001: inferred dual-port weight array (OI-001 = SRAM-macro boundary).
    reg [15:0] mem [0:W_TOT-1];

    // FSM-003 registers (written ONLY in the walk FSM block below).
    reg             state_r;              // 1-bit binary FSM-003 state
    reg [W_A-1:0]   walk_addr;            // bulk-init write pointer

    //-----------------------------------------------------------------
    // Port-B write-path arbitration mux (combinational; blocking =).
    // init_busy selects the walk over the CSR: while the walk owns port B a
    // CSR WDATA write is discarded (b_we ignored) and the walk drives the
    // address/data/enable (arch.md section 4.5 / section 7). Default-assign
    // every LHS first so no latch can be inferred.
    //-----------------------------------------------------------------
    reg [W_A-1:0]   b_addr_eff;           // effective port-B address (CSR or walk)
    reg [15:0]      b_wdata_eff;          // effective port-B write data
    reg             b_we_eff;             // effective port-B write enable

    always @* begin
        b_addr_eff  = b_addr;             // default: CSR owns port B
        b_wdata_eff = b_wdata;
        b_we_eff    = b_we;
        if (init_busy) begin              // walk owns port B: drop CSR, drive walk
            b_addr_eff  = walk_addr;
            b_wdata_eff = init_val;
            b_we_eff    = 1'b1;
        end
    end

    //-----------------------------------------------------------------
    // Combinational (asynchronous) reads.
    // Port B during init_busy returns mem[walk_addr] (the "current word",
    // benign per arch.md section 4.5) because b_addr_eff == walk_addr then.
    //-----------------------------------------------------------------
    assign a_rdata = mem[a_addr];
    assign b_rdata = mem[b_addr_eff];

    //-----------------------------------------------------------------
    // MEM WRITE - single owner of `mem` (guidelines section 6: a reg may not
    // be assigned from two always blocks; a shared dual-WRITE-port array
    // cannot be split across two blocks without becoming multiply-driven, so
    // both write PATHS live here as separate, clearly-scoped statements).
    //
    // Read-during-write: reads are asynchronous and this write is synchronous,
    // so within the writing cycle the read port shows the pre-write word and
    // the newly written word appears from the clock edge onward. FSM-001
    // separates a read from its dependent write by >= 1 clock, so this is
    // never relied upon downstream (arch.md section 4.5 labels the intent
    // "write-first"; the separation makes the exact RDW mode immaterial).
    //
    // Same-cycle same-address A/B conflict does not occur by design (port A =
    // training, port B = CSR/init run in disjoint phases); should it ever
    // occur, port B (last non-blocking assignment) wins, deterministically.
    //
    // Synchronous reset clears every word to 0 (arch.md section 4.5). At the
    // default config this is a 25,450-word loop; acceptable for simulation,
    // and it is the boundary an SRAM macro replaces at integration (OI-001).
    //-----------------------------------------------------------------
    always @(posedge clk_core) begin : mem_wr
        integer i;                        // block-local loop var (never shared)
        if (!rst_n) begin
            for (i = 0; i < W_TOT; i = i + 1)
                mem[i] <= 16'h0000;
        end else begin
            if (a_we)                     // port A write path (learner, IFI-004)
                mem[a_addr] <= a_wdata;
            if (b_we_eff)                 // port B write path (CSR or walk, IFI-005)
                mem[b_addr_eff] <= b_wdata_eff;
        end
    end

    //-----------------------------------------------------------------
    // FSM-003 init_walk - single owner of state_r / walk_addr / init_busy.
    // Registered Moore machine (state and outputs clocked together). The
    // actual memory write is issued by the port-B mux above while init_busy;
    // this block only sequences the walk. `default:` recovers illegal states
    // to IDLE (arch.md section 6.3).
    //   IDLE: init_go        -> init_busy=1, walk_addr=0, go WALK
    //   WALK: addr <  LAST    -> (mem[addr]<=init_val via mux) addr++, stay
    //         addr == LAST     -> (final mem write via mux) init_busy=0, IDLE
    //-----------------------------------------------------------------
    always @(posedge clk_core) begin
        if (!rst_n) begin
            state_r   <= ST_IDLE;
            walk_addr <= {W_A{1'b0}};
            init_busy <= 1'b0;
        end else begin
            case (state_r)
                ST_IDLE: begin
                    if (init_go) begin
                        init_busy <= 1'b1;
                        walk_addr <= {W_A{1'b0}};
                        state_r   <= ST_WALK;
                    end
                end
                ST_WALK: begin
                    if (walk_addr == WALK_LAST) begin
                        // final word written this cycle by the port-B mux
                        init_busy <= 1'b0;
                        state_r   <= ST_IDLE;
                    end else begin
                        walk_addr <= walk_addr + 1'b1;   // W_A-bit increment
                    end
                end
                default: begin            // illegal-state recovery -> IDLE
                    state_r   <= ST_IDLE;
                    init_busy <= 1'b0;
                    walk_addr <= {W_A{1'b0}};
                end
            endcase
        end
    end

endmodule

`default_nettype wire                     // restore for tools that need it
