`timescale 1ns / 100ps

// fp32 to a float with 8 exponent bits: round to nearest even, NaN to the canonical qNaN, exponent 0 to a signed zero, overflow to infinity.
module fpNarrow #(
    parameter int EXP_W = 8,
    parameter int MAN_W = 7,
    parameter int W     = 1 + EXP_W + MAN_W
) (
    input  logic [31:0]  x_i,
    output logic [W-1:0] y_o
);
  localparam int SH = 23 - MAN_W;
  if (EXP_W != 8 || MAN_W > 23 || MAN_W < 1) begin : G_BAD_FORMAT
    $fatal(1, "fpNarrow: EXP_W=%0d MAN_W=%0d: only 8 exponent bits and 1..23 mantissa bits", EXP_W, MAN_W);
  end else if (SH == 0) begin : G_ID
    assign y_o = x_i;
  end else begin : G_NARROW
    logic nan, tiny;
    logic [31:0] r;
    assign nan  = (x_i[30:23] == 8'hFF) && (x_i[22:0] != '0);
    assign tiny = (x_i[30:23] == 8'h00);
    assign r    = (x_i + ((32'd1 << (SH - 1)) - 32'd1) + 32'((x_i >> SH) & 32'd1)) >> SH;  // carries into the exponent, and to infinity
    assign y_o  = nan ? {1'b0, {EXP_W{1'b1}}, 1'b1, {(MAN_W - 1){1'b0}}} : tiny ? {x_i[31], {(W - 1){1'b0}}} : r[W-1:0];
  end
endmodule
