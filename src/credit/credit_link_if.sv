`timescale 1ns / 100ps

// One credit link: the consumer grants credits (one per free slot), the producer spends one per put.
// Both ends share one reset: an advertisement made while the other end is in reset is lost.
/* verilator lint_off UNUSEDSIGNAL */
interface credit_link_if #(parameter int DATA_W = 32, parameter int CRW = 1);
  logic              put;     // producer: one item this cycle
  logic [DATA_W-1:0] data;    // producer: the item
  logic [CRW-1:0]    credit;  // consumer: slots freed this cycle; after reset, the slots it advertises
  modport producer (output put, data, input  credit);
  modport consumer (input  put, data, output credit);
  modport monitor  (input  put, data, credit);
endinterface
/* verilator lint_on UNUSEDSIGNAL */
