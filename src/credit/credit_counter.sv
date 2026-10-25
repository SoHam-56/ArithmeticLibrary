`timescale 1ns / 100ps

// Producer-side credit count: every credit adds, every put spends one.
// Contract: cnt + credit - put never exceeds MAX, so a consumer may return a slot's credit in the cycle of the put that fills it.
module credit_counter #(parameter int MAX = 32, parameter int CRW = 1) (
    input  logic clk_i, rstn_i,
    input  logic           put_i,
    input  logic [CRW-1:0] credit_i,
    output logic           has_credit_o,
    output logic [$clog2(MAX + 1)-1:0] count_o
);
  localparam int CW = $clog2(MAX + 1);
  if (MAX < 1) begin : G_BAD_MAX  // a counter that can never hold a credit
    $fatal(1, "credit_counter: MAX %0d must be at least 1", MAX);
  end else if (CRW > CW) begin : G_BAD_CRW  // the credit's high bits would be dropped silently
    $fatal(1, "credit_counter: CRW %0d is wider than the count's %0d bits (MAX %0d)", CRW, CW, MAX);
  end
  logic [CW-1:0] cnt;
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) cnt <= '0;
    else cnt <= cnt + CW'(credit_i) - CW'(put_i);
  assign has_credit_o = cnt != 0;
  assign count_o = cnt;
`ifndef SYNTHESIS
  a_no_underflow: assert property (@(posedge clk_i) disable iff (!rstn_i) put_i |-> cnt != 0)
    else $error("credit_counter: put without a credit");
  a_no_overflow: assert property (@(posedge clk_i) disable iff (!rstn_i) int'(cnt) + int'(credit_i) - int'(put_i) <= MAX)
    else $error("credit_counter: more credits than MAX");
`endif
endmodule
