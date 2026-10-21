`timescale 1ns / 100ps

// fp32 to bf16, combinational: fpNarrow's algorithm with the format fixed at 8 exponent and 7 mantissa bits. Round to nearest even,
// NaN to the canonical qNaN, exponent 0 to a signed zero, overflow to infinity.
module fp32ToBf16 #(
    localparam int EXPONENT_WIDTH = 8,
    localparam int MANTISSA_WIDTH = 7,
    localparam int DATA_WIDTH = 16
) (
    input  logic [31:0]  fp32_i,
    output logic [DATA_WIDTH-1:0] bf16_o
);
  localparam int DROPPED_MANTISSA_BITS = 23 - MANTISSA_WIDTH;
  if (EXPONENT_WIDTH != 8 || MANTISSA_WIDTH > 23 || MANTISSA_WIDTH < 1) begin : G_BAD_FORMAT
    $fatal(1, "fp32ToBf16: EXPONENT_WIDTH=%0d MANTISSA_WIDTH=%0d: only 8 exponent bits and 1..23 mantissa bits", EXPONENT_WIDTH, MANTISSA_WIDTH);
  end else if (DROPPED_MANTISSA_BITS == 0) begin : G_ID
    assign bf16_o = fp32_i;
  end else begin : G_NARROW
    logic nan, zero_exponent;
    /* verilator lint_off UNUSEDSIGNAL */  // rounded_word's bits above DATA_WIDTH are zero after the shift
    logic [31:0] rounded_word;
    /* verilator lint_on UNUSEDSIGNAL */
    assign nan  = (fp32_i[30:23] == 8'hFF) && (fp32_i[22:0] != '0);
    assign zero_exponent = (fp32_i[30:23] == 8'h00);
    assign rounded_word    = (fp32_i + ((32'd1 << (DROPPED_MANTISSA_BITS - 1)) - 32'd1) + 32'((fp32_i >> DROPPED_MANTISSA_BITS) & 32'd1)) >> DROPPED_MANTISSA_BITS;  // carries into the exponent, and to infinity
    assign bf16_o  = nan ? {1'b0, {EXPONENT_WIDTH{1'b1}}, 1'b1, {(MANTISSA_WIDTH - 1){1'b0}}} : zero_exponent ? {fp32_i[31], {(DATA_WIDTH - 1){1'b0}}} : rounded_word[DATA_WIDTH-1:0];
  end
endmodule
