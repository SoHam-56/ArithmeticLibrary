`timescale 1ns / 100ps

// Protocol checker on a link: no put without a credit, credits outstanding never above SLOTS, all returned when drained.
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
module credit_link_checker #(parameter int SLOTS = 32) (
    input logic clk_i, rstn_i, drained_i,
    credit_link_if.monitor lnk
);
`ifndef SYNTHESIS
  int granted;  // credits seen and not yet spent
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) granted <= 0;
    else granted <= granted + int'(lnk.credit) - int'(lnk.put);
  a_put_has_credit: assert property (@(posedge clk_i) disable iff (!rstn_i) lnk.put |-> granted > 0)
    else $error("credit_link_checker: put without a credit");
  a_within_slots: assert property (@(posedge clk_i) disable iff (!rstn_i) granted <= SLOTS)
    else $error("credit_link_checker: more credits outstanding than SLOTS");
  a_all_back: assert property (@(posedge clk_i) disable iff (!rstn_i) drained_i |-> granted == SLOTS)
    else $error("credit_link_checker: link drained with %0d of %0d credits", granted, SLOTS);
`endif
endmodule
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
