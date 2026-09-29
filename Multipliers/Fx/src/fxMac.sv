`timescale 1ns / 100ps

// Fixed-point multiply-add, one Horner step: result_o = sat_W(floor(A * X / 2^FRAC) + C); done_o at t+2; only valid bits reset (D-8).
module fxMac #(
    parameter int W    = 16,
    parameter int FRAC = 11
) (
    input  logic                clk_i,
    input  logic                rstn_i,
    input  logic                valid_i,
    input  logic signed [W-1:0] A,
    input  logic signed [W-1:0] X,
    input  logic signed [W-1:0] C,
    output logic signed [W-1:0] result_o,
    output logic                done_o
);
  localparam int PW = 2 * W;

  // Stage 1: the exact product (|A * X| <= 2^(2W-2)) and the addend.
  logic                 s1_v;
  logic signed [PW-1:0] s1_p;
  logic signed [W-1:0]  s1_c;

  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) s1_v <= 1'b0;
    else s1_v <= valid_i;

  always_ff @(posedge clk_i)
    if (valid_i) begin
      s1_p <= PW'(A) * PW'(X);
      s1_c <= C;
    end

  // Stage 2: the sum fits 2W bits (|p >>> FRAC| <= 2^(2W-2), |C| <= 2^(W-1)); it fits W bits when its top W+1 bits agree.
  logic signed [PW-1:0] sum;
  logic                 fits;
  assign sum  = (s1_p >>> FRAC) + PW'(s1_c);
  assign fits = (sum[PW-1:W-1] == '0) || (sum[PW-1:W-1] == '1);

  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) done_o <= 1'b0;
    else done_o <= s1_v;

  always_ff @(posedge clk_i)
    if (s1_v) result_o <= fits ? sum[W-1:0] : {sum[PW-1], {(W - 1) {~sum[PW-1]}}};

endmodule
