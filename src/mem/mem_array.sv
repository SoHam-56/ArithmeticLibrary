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
  if (WIDTH % MASK_W != 0 || MASK_W < 1) begin : G_BAD_MASK
    $fatal(1, "mem_array: MASK_W %0d must divide WIDTH %0d", MASK_W, WIDTH);
  end
  if (DEPTH < 1 || NW < 1 || NR < 1) begin : G_BAD_SHAPE
    $fatal(1, "mem_array: DEPTH %0d, NW %0d and NR %0d must be at least 1", DEPTH, NW, NR);
  end

  logic [WIDTH-1:0] mem[DEPTH];

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
