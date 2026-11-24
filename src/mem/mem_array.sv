`timescale 1ns / 100ps

// A memory array behind its own module boundary, so synthesis can replace it by name with a macro or an ideal stub while simulation keeps
// the flop array. DEPTH rows of WIDTH bits; NW write ports, each a whole row under a mask of WIDTH/MASK_W units; NR read ports, each a row:
// SYNC_READ 1 gives the row one cycle after an enabled read and holds it, 0 gives it combinationally. Two ports writing one row in a cycle:
// the higher-numbered port wins per mask unit. Nothing is reset (D-8): a row is read only after it was written; ZERO_INIT 1 clears the array
// in simulation unless NO_ZERO_INIT (random power-up) is defined.
module mem_array #(
    parameter int DEPTH     = 16,
    parameter int WIDTH     = 32,
    parameter int NW        = 1,
    parameter int NR        = 1,
    parameter int MASK_W    = WIDTH,  // bits per write-mask unit; WIDTH masks the whole row with one bit
    parameter bit SYNC_READ = 1'b1,
    parameter bit ZERO_INIT = 1'b0,
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
  logic [WIDTH-1:0] mem[DEPTH];

  if (WIDTH % MASK_W != 0 || MASK_W < 1) begin : G_BAD_MASK
    $fatal(1, "mem_array: MASK_W %0d must divide WIDTH %0d", MASK_W, WIDTH);
  end
  if (DEPTH < 1 || NW < 1 || NR < 1) begin : G_BAD_SHAPE
    $fatal(1, "mem_array: DEPTH %0d, NW %0d and NR %0d must be at least 1", DEPTH, NW, NR);
  end

  always_ff @(posedge clk_i)
    for (int p = 0; p < NW; p++)
      if (we_i[p])
        for (int u = 0; u < MU; u++)
          if (wmask_i[p][u]) mem[waddr_i[p]][u*MASK_W+:MASK_W] <= wdata_i[p][u*MASK_W+:MASK_W];

  if (SYNC_READ) begin : G_SYNC
    always_ff @(posedge clk_i)
      for (int p = 0; p < NR; p++)
        if (re_i[p]) rdata_o[p] <= mem[raddr_i[p]];
  end else begin : G_COMB
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
