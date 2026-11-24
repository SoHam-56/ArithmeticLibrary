`timescale 1ns / 100ps

// A memory array behind its own module boundary, so synthesis can replace it by name with a macro or an ideal stub while simulation keeps
// the flop array. DEPTH rows of WIDTH bits; NW write ports, each a whole row under a mask of WIDTH/MASK_W units; NR read ports, each a row:
// SYNC_READ 1 gives the row one cycle after an enabled read and holds it, 0 gives it combinationally. Two ports writing one row in a cycle:
// the higher-numbered port wins per mask unit. Nothing is reset (D-8): a row is read only after it was written; ZERO_INIT 1 clears the array
// in simulation unless NO_ZERO_INIT (random power-up) is defined.
//
// IMPL picks the mapping at the call site, the users unchanged: "FLOPS" (the default: the flop array above, as before), or banks of
// SRAM-macro models, "SP" (mem_bank_sp: one port, a read or a write per cycle) or "DP" (mem_bank_dp: one write and one read port), each
// with a synchronous read and a write mask as OpenRAM's macros have. Address a sits in bank (a / BANK_STRIDE) % BANKS, at row
// (a / (BANK_STRIDE * BANKS)) * BANK_STRIDE + a % BANK_STRIDE: BANK_STRIDE 1 interleaves rows, BANK_STRIDE s keeps runs of s rows
// together. Each bank takes the port addressing it that cycle; a read port's word comes from the bank it read a cycle earlier and holds
// otherwise, as the flop array's does. Assertions (simulation) prove every cycle fits the ports: SP at most one access per bank, DP at
// most one write and one read and never both on one row (OpenRAM leaves a dual-port read of the row being written undefined).
module mem_array #(
    parameter int DEPTH     = 16,
    parameter int WIDTH     = 32,
    parameter int NW        = 1,
    parameter int NR        = 1,
    parameter int MASK_W    = WIDTH,  // bits per write-mask unit; WIDTH masks the whole row with one bit
    parameter bit SYNC_READ = 1'b1,
    parameter bit ZERO_INIT = 1'b0,
    parameter string IMPL   = "FLOPS",  // "FLOPS", "SP" or "DP"
    parameter int BANKS       = 1,  // SP / DP: banks, a power of two
    parameter int BANK_STRIDE = 1,  // SP / DP: rows kept together in a bank, a power of two
    parameter int AW        = (DEPTH > 1) ? $clog2(DEPTH) : 1,
    parameter int MU        = WIDTH / MASK_W  // mask units per row
) (
    input  logic                     clk_i,
    input  logic [NW-1:0]            we_i,
    input  logic [NW-1:0][   AW-1:0] waddr_i,
    input  logic [NW-1:0][   MU-1:0] wmask_i,
    input  logic [NW-1:0][WIDTH-1:0] wdata_i,
    input  logic [NR-1:0]            re_i,     // SYNC_READ: load the port's row register; ignored when combinational
    input  logic [NR-1:0][   AW-1:0] raddr_i,
    output logic [NR-1:0][WIDTH-1:0] rdata_o
);
  /* verilator lint_off UNUSEDSIGNAL */
  logic [WIDTH-1:0] mem[DEPTH];  // the flop array (IMPL FLOPS; kept by name for the benches that trace it)
  /* verilator lint_on UNUSEDSIGNAL */

  if (WIDTH % MASK_W != 0 || MASK_W < 1) begin : G_BAD_MASK
    $fatal(1, "mem_array: MASK_W %0d must divide WIDTH %0d", MASK_W, WIDTH);
  end
  if (DEPTH < 1 || NW < 1 || NR < 1) begin : G_BAD_SHAPE
    $fatal(1, "mem_array: DEPTH %0d, NW %0d and NR %0d must be at least 1", DEPTH, NW, NR);
  end

  if (IMPL != "FLOPS" && IMPL != "SP" && IMPL != "DP") begin : G_BAD_IMPL
    $fatal(1, "mem_array: IMPL \"%s\" is not FLOPS, SP or DP", IMPL);
  end
  if (IMPL != "FLOPS" && (!SYNC_READ || BANKS < 1 || (BANKS & (BANKS - 1)) != 0 || BANK_STRIDE < 1 || (BANK_STRIDE & (BANK_STRIDE - 1)) != 0
                          || DEPTH % (BANKS * BANK_STRIDE) != 0)) begin : G_BAD_BANKS
    $fatal(1, "mem_array: IMPL %s needs SYNC_READ 1, BANKS (%0d) and BANK_STRIDE (%0d) powers of two, and DEPTH (%0d) a multiple of their product",
           IMPL, BANKS, BANK_STRIDE, DEPTH);
  end

  if (IMPL == "FLOPS") begin : G_FLOP_WRITE
    always_ff @(posedge clk_i)
      for (int p = 0; p < NW; p++)
        if (we_i[p])
          for (int u = 0; u < MU; u++)
            if (wmask_i[p][u]) mem[waddr_i[p]][u*MASK_W+:MASK_W] <= wdata_i[p][u*MASK_W+:MASK_W];
  end

  if (IMPL != "FLOPS") begin : G_BANKED
    localparam int ROWS = DEPTH / BANKS;
    localparam int BAW = (BANKS > 1) ? $clog2(BANKS) : 1;
    localparam int RAW = (ROWS > 1) ? $clog2(ROWS) : 1;
    localparam int SW = $clog2(BANK_STRIDE);  // 0 for a stride of 1
    localparam int BW = $clog2(BANKS);
    function automatic logic [BAW-1:0] bank_of(input logic [AW-1:0] a);
      return BAW'((int'(a) >> SW) & (BANKS - 1));
    endfunction
    function automatic logic [RAW-1:0] row_of(input logic [AW-1:0] a);
      return RAW'(((int'(a) >> (SW + BW)) << SW) | (int'(a) & (BANK_STRIDE - 1)));
    endfunction
    logic [BANKS-1:0]           b_we, b_re;
    logic [BANKS-1:0][RAW-1:0]  b_waddr, b_raddr;
    logic [BANKS-1:0][MU-1:0]   b_wmask;
    logic [BANKS-1:0][WIDTH-1:0] b_wdata, b_rdata;
    logic [NR-1:0][BAW-1:0]     rd_bank_q;  // the bank each read port read, a cycle on
    logic [NR-1:0]              rd_q;
    logic [NR-1:0][WIDTH-1:0]   rd_hold;
    // Each bank takes the port addressing it (the highest-numbered, as the flop array's write priority; the assertions keep it to one).
    always_comb
      for (int b = 0; b < BANKS; b++) begin
        b_we[b] = 1'b0; b_waddr[b] = '0; b_wmask[b] = '0; b_wdata[b] = '0;
        b_re[b] = 1'b0; b_raddr[b] = '0;
        for (int p = 0; p < NW; p++)
          if (we_i[p] && int'(bank_of(waddr_i[p])) == b) begin
            b_we[b] = 1'b1; b_waddr[b] = row_of(waddr_i[p]); b_wmask[b] = wmask_i[p]; b_wdata[b] = wdata_i[p];
          end
        for (int p = 0; p < NR; p++)
          if (re_i[p] && int'(bank_of(raddr_i[p])) == b) begin
            b_re[b] = 1'b1; b_raddr[b] = row_of(raddr_i[p]);
          end
      end
    for (genvar b = 0; b < BANKS; b++) begin : G_BANK
      if (IMPL == "SP") begin : G_SP
        mem_bank_sp #(.ROWS(ROWS), .WIDTH(WIDTH), .MASK_W(MASK_W), .ZERO_INIT(ZERO_INIT)) bank (.clk_i(clk_i), .we_i(b_we[b]),
            .re_i(b_re[b]), .addr_i(b_we[b] ? b_waddr[b] : b_raddr[b]), .wmask_i(b_wmask[b]), .wdata_i(b_wdata[b]), .rdata_o(b_rdata[b]));
      end else begin : G_DP
        mem_bank_dp #(.ROWS(ROWS), .WIDTH(WIDTH), .MASK_W(MASK_W), .ZERO_INIT(ZERO_INIT)) bank (.clk_i(clk_i), .we_i(b_we[b]),
            .waddr_i(b_waddr[b]), .wmask_i(b_wmask[b]), .wdata_i(b_wdata[b]), .re_i(b_re[b]), .raddr_i(b_raddr[b]), .rdata_o(b_rdata[b]));
      end
    end
    // A read port's word: the bank it read a cycle earlier, else its held word.
    always_ff @(posedge clk_i) begin
      for (int p = 0; p < NR; p++) begin
        rd_q[p] <= re_i[p];
        if (re_i[p]) rd_bank_q[p] <= bank_of(raddr_i[p]);
      end
      rd_hold <= rdata_o;
    end
    always_comb for (int p = 0; p < NR; p++) rdata_o[p] = rd_q[p] ? b_rdata[rd_bank_q[p]] : rd_hold[p];
`ifndef SYNTHESIS
    // The ports each cycle needs, per bank: SP one access, DP one write and one read, never on the same row.
    always @(posedge clk_i) begin
      for (int b = 0; b < BANKS; b++) begin
        automatic int nw, nr;
        automatic logic same;
        nw = 0; nr = 0; same = 1'b0;
        for (int p = 0; p < NW; p++) if (we_i[p] === 1'b1 && int'(bank_of(waddr_i[p])) == b) nw++;
        for (int p = 0; p < NR; p++) if (re_i[p] === 1'b1 && int'(bank_of(raddr_i[p])) == b) nr++;
        for (int p = 0; p < NW; p++)
          for (int q = 0; q < NR; q++)
            if (we_i[p] === 1'b1 && re_i[q] === 1'b1 && waddr_i[p] == raddr_i[q] && int'(bank_of(waddr_i[p])) == b) same = 1'b1;
        if (IMPL == "SP" && nw + nr > 1)
          $error("mem_array: a_bank_ports: %m bank %0d has %0d writes and %0d reads this cycle; SP allows one access", b, nw, nr);
        if (IMPL == "DP" && (nw > 1 || nr > 1 || same))
          $error("mem_array: a_bank_ports: %m bank %0d has %0d writes and %0d reads this cycle%s; DP allows one of each on different rows", b, nw,
                 nr, same ? ", a read of the row being written" : "");
      end
    end
`endif
  end

  if (IMPL == "FLOPS" && SYNC_READ) begin : G_SYNC
    always_ff @(posedge clk_i)
      for (int p = 0; p < NR; p++)
        if (re_i[p]) rdata_o[p] <= mem[raddr_i[p]];
  end else if (IMPL == "FLOPS") begin : G_COMB
    always_comb for (int p = 0; p < NR; p++) rdata_o[p] = mem[raddr_i[p]];
    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_re;
    assign unused_re = ^re_i;
    /* verilator lint_on UNUSEDSIGNAL */
  end

`ifdef MEM_AUDIT
  // The banking audit (simulation only, +define+MEM_AUDIT): per cycle, how many write and read ports touch each bank, for B banks by
  // address blocks (addr / (DEPTH / B)) and by interleave (addr % B), B = 2 .. 64; the worst counts per instance are printed at the end.
  // A banking is single-port legal where reads + writes per bank per cycle stay at 1, one-read-one-write legal where each stays at 1.
  // Reads are counted where re_i is set; a combinational-read user that ties re_i high is counted every cycle (an upper bound).
  localparam int NB = 6;  // B = 2, 4, 8, 16, 32, 64
  int aw_max[2][NB], ar_max[2][NB], arw_max[2][NB];  // [block 0 / interleave 1][B index]
  longint a_cycles, a_wr, a_rd;
  initial begin
    for (int m = 0; m < 2; m++) for (int b = 0; b < NB; b++) {aw_max[m][b], ar_max[m][b], arw_max[m][b]} = '0;
    {a_cycles, a_wr, a_rd} = '0;
  end
  /* verilator lint_off BLKSEQ */  // the audit's own counters, simulation only
  always @(posedge clk_i) begin
    automatic int wc[64], rc[64];
    a_cycles++;
    for (int p = 0; p < NW; p++) a_wr += we_i[p];
    for (int p = 0; p < NR; p++) a_rd += re_i[p];
    for (int m = 0; m < 2; m++)
      for (int bi = 0; bi < NB; bi++) begin
        automatic int nb, blk;  // assigned, not initialized: xsim may keep an automatic initializer's first value
        nb  = 2 << bi;
        blk = (DEPTH + nb - 1) / nb;
        for (int k = 0; k < 64; k++) begin wc[k] = 0; rc[k] = 0; end
        for (int p = 0; p < NW; p++) if (we_i[p]) wc[(m == 0) ? int'(waddr_i[p]) / blk : int'(waddr_i[p]) % nb]++;
        for (int p = 0; p < NR; p++) if (re_i[p]) rc[(m == 0) ? int'(raddr_i[p]) / blk : int'(raddr_i[p]) % nb]++;
        for (int k = 0; k < nb; k++) begin
          if (wc[k] > aw_max[m][bi]) aw_max[m][bi] = wc[k];
          if (rc[k] > ar_max[m][bi]) ar_max[m][bi] = rc[k];
          if (wc[k] + rc[k] > arw_max[m][bi]) arw_max[m][bi] = wc[k] + rc[k];
        end
      end
  end
  /* verilator lint_on BLKSEQ */
  final begin
    $display("MEM_AUDIT %m DEPTH=%0d WIDTH=%0d NW=%0d NR=%0d SYNC=%0d cycles=%0d writes=%0d reads=%0d", DEPTH, WIDTH, NW, NR, SYNC_READ, a_cycles,
             a_wr, a_rd);
    for (int bi = 0; bi < NB; bi++)
      if ((2 << bi) <= DEPTH)
        $display("MEM_AUDIT %m B=%0d block w%0d r%0d rw%0d interleave w%0d r%0d rw%0d", 2 << bi, aw_max[0][bi], ar_max[0][bi], arw_max[0][bi],
                 aw_max[1][bi], ar_max[1][bi], arw_max[1][bi]);
  end
`endif

`ifdef SYNTHESIS
  /* verilator lint_off UNUSEDPARAM */
  localparam bit UNUSED_ZERO_INIT = ZERO_INIT;  // simulation only
  /* verilator lint_on UNUSEDPARAM */
`elsif NO_ZERO_INIT  // silicon powers up random; NO_ZERO_INIT checks that nothing reads a row before it is written
  /* verilator lint_off UNUSEDPARAM */
  localparam bit UNUSED_ZERO_INIT = ZERO_INIT;
  /* verilator lint_on UNUSEDPARAM */
`else
  if (ZERO_INIT) begin : G_INIT
    initial for (int i = 0; i < DEPTH; i++) mem[i] = '0;
  end
`endif

endmodule

// The bank models live in this file (not one module per file) so every flow that reads mem_array.sv has them.
/* verilator lint_off DECLFILENAME */
// One SRAM bank as a single-port macro sees it: a read or a write per cycle on addr_i (a write wins), the read word on rdata_o the cycle
// after and held until the next read. A separate module so synthesis can replace it by name with an OpenRAM 1rw macro of ROWS x WIDTH.
module mem_bank_sp #(
    parameter int ROWS      = 16,
    parameter int WIDTH     = 32,
    parameter int MASK_W    = WIDTH,
    parameter bit ZERO_INIT = 1'b0,
    parameter int RAW       = (ROWS > 1) ? $clog2(ROWS) : 1,
    parameter int MU        = WIDTH / MASK_W
) (
    input  logic             clk_i,
    input  logic             we_i,
    input  logic             re_i,
    input  logic [  RAW-1:0] addr_i,
    input  logic [   MU-1:0] wmask_i,
    input  logic [WIDTH-1:0] wdata_i,
    output logic [WIDTH-1:0] rdata_o
);
  logic [WIDTH-1:0] mem[ROWS];
  always_ff @(posedge clk_i)
    if (we_i) begin
      for (int u = 0; u < MU; u++) if (wmask_i[u]) mem[addr_i][u*MASK_W+:MASK_W] <= wdata_i[u*MASK_W+:MASK_W];
    end else if (re_i) rdata_o <= mem[addr_i];
`ifndef SYNTHESIS
`ifndef NO_ZERO_INIT
  if (ZERO_INIT) begin : G_INIT
    initial for (int i = 0; i < ROWS; i++) mem[i] = '0;
  end
`endif
`endif
endmodule

// One SRAM bank as a dual-port macro sees it: a write on waddr_i and a read on raddr_i each cycle, the read word on rdata_o the cycle after
// and held until the next read. A separate module so synthesis can replace it by name with an OpenRAM 1rw1r macro of ROWS x WIDTH.
module mem_bank_dp #(
    parameter int ROWS      = 16,
    parameter int WIDTH     = 32,
    parameter int MASK_W    = WIDTH,
    parameter bit ZERO_INIT = 1'b0,
    parameter int RAW       = (ROWS > 1) ? $clog2(ROWS) : 1,
    parameter int MU        = WIDTH / MASK_W
) (
    input  logic             clk_i,
    input  logic             we_i,
    input  logic [  RAW-1:0] waddr_i,
    input  logic [   MU-1:0] wmask_i,
    input  logic [WIDTH-1:0] wdata_i,
    input  logic             re_i,
    input  logic [  RAW-1:0] raddr_i,
    output logic [WIDTH-1:0] rdata_o
);
  logic [WIDTH-1:0] mem[ROWS];
  always_ff @(posedge clk_i) begin
    if (we_i) for (int u = 0; u < MU; u++) if (wmask_i[u]) mem[waddr_i][u*MASK_W+:MASK_W] <= wdata_i[u*MASK_W+:MASK_W];
    if (re_i) rdata_o <= mem[raddr_i];
  end
`ifndef SYNTHESIS
`ifndef NO_ZERO_INIT
  if (ZERO_INIT) begin : G_INIT
    initial for (int i = 0; i < ROWS; i++) mem[i] = '0;
  end
`endif
`endif
endmodule
/* verilator lint_on DECLFILENAME */
