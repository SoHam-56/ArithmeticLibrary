`timescale 1ns / 100ps

// The generic W x W signed multiplier the per-width units are proven against (eq_tops.sv): the product as the language defines it,
// registered once, then delayed to the unit's STAGES, so the equivalence compares intMulPipe's tree with the plain product, not with
// itself.
module intMultiplier #(
    parameter int W      = 8,
    parameter int STAGES = 2
) (
    input  logic                  clk_i,
    input  logic                  rstn_i,
    input  logic                  valid_i,
    input  logic signed [W-1:0]   A,
    input  logic signed [W-1:0]   B,
    output logic signed [2*W-1:0] result_o,
    output logic                  done_o
);
  if (STAGES < 1) begin : G_BAD_STAGES
    $fatal(1, "intMultiplier: STAGES %0d, at least 1", STAGES);
  end
  logic [STAGES-1:0] v;
  logic signed [2*W-1:0] p[STAGES];
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) v <= '0;
    else v <= STAGES'({v, valid_i});
  always_ff @(posedge clk_i) begin
    if (valid_i) p[0] <= (2 * W)'(A) * (2 * W)'(B);
    for (int i = 1; i < STAGES; i++) if (v[i-1]) p[i] <= p[i-1];
  end
  assign result_o = p[STAGES-1];
  assign done_o   = v[STAGES-1];

endmodule
