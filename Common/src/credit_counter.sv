`timescale 1ns / 100ps

// Producer-side credit count: every credit adds, every put spends one.
module credit_counter #(parameter int MAX = 32, parameter int CRW = 1) (
    input  logic clk_i, rstn_i,
    input  logic           put_i,
    input  logic [CRW-1:0] credit_i,
    output logic           has_credit_o,
    output logic [$clog2(MAX + 1)-1:0] count_o
);
  localparam int CW = $clog2(MAX + 1);
  logic [CW-1:0] cnt;
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) cnt <= '0;
    else cnt <= cnt + CW'(credit_i) - CW'(put_i);
  assign has_credit_o = cnt != 0;
  assign count_o = cnt;
`ifndef SYNTHESIS
  a_no_underflow: assert property (@(posedge clk_i) disable iff (!rstn_i) put_i |-> cnt != 0)
    else $error("credit_counter: put without a credit");
  a_no_overflow: assert property (@(posedge clk_i) disable iff (!rstn_i) (cnt + CW'(credit_i)) <= MAX)
    else $error("credit_counter: more credits than MAX");
`endif
endmodule
