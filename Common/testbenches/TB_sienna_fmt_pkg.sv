`timescale 1ns / 100ps

// Checks sienna_fmt_pkg: supported formats, accumulator widths, unit latencies, and constants narrowed from fp32.
module TB_sienna_fmt_pkg;
  import sienna_fmt_pkg::*;
  int errs = 0;

  // The functions must work in constant expressions, as generate blocks use them.
  localparam int ACC8 = acc_w(0, 7);
  localparam int MUL8 = mul_lat(0, 7);
  localparam bit INT8 = is_int(0);
  localparam int FX8 = fx_lat();
  localparam int RQ8 = req_lat();

  task automatic expect_eq(input string what, input longint got, input longint want);
    if (got != want) begin
      errs++;
      $display("[FAIL] %s: got %0h, want %0h", what, got, want);
    end
  endtask

  initial begin
    expect_eq("is_fp32(8,23)", is_fp32(8, 23), 1);
    expect_eq("is_fp32(8,7)", is_fp32(8, 7), 0);
    expect_eq("is_fp32(0,7)", is_fp32(0, 7), 0);
    expect_eq("supported(8,23)", supported(8, 23), 1);
    expect_eq("supported(8,7)", supported(8, 7), 1);
    expect_eq("supported(0,7)", supported(0, 7), 1);
    expect_eq("supported(5,10)", supported(5, 10), 0);
    expect_eq("supported(0,15)", supported(0, 15), 0);
    expect_eq("supported(0,3)", supported(0, 3), 0);
    expect_eq("is_int(0)", is_int(0), 1);
    expect_eq("is_int(8)", is_int(8), 0);
    expect_eq("acc_w(0,7)", acc_w(0, 7), 32);
    expect_eq("acc_w(8,23)", acc_w(8, 23), 32);
    expect_eq("acc_w(8,7)", acc_w(8, 7), 16);
    expect_eq("mul_lat(8,23)", mul_lat(8, 23), 8);
    expect_eq("mul_lat(8,7)", mul_lat(8, 7), 3);
    expect_eq("mul_lat(0,7)", mul_lat(0, 7), 1);
    expect_eq("add_lat(8,23)", add_lat(8, 23), 5);
    expect_eq("add_lat(8,7)", add_lat(8, 7), 5);
    expect_eq("add_lat(0,7)", add_lat(0, 7), 1);
    expect_eq("fx_lat()", fx_lat(), 2);
    expect_eq("req_lat()", req_lat(), 3);
    expect_eq("REQ_ROUNDING is SINGLE or DOUBLE", (REQ_ROUNDING == "SINGLE") || (REQ_ROUNDING == "DOUBLE"), 1);
    expect_eq("ACC8 localparam", ACC8, 32);
    expect_eq("MUL8 localparam", MUL8, 1);
    expect_eq("INT8 localparam", INT8, 1);
    expect_eq("FX8 localparam", FX8, 2);
    expect_eq("RQ8 localparam", RQ8, 3);
    expect_eq("1.0", from_fp32(32'h3F800000, 7), 32'h3F80);
    expect_eq("lambda", from_fp32(32'h3F867D5F, 7), 32'h3F86);  // low half 7D5F rounds down
    expect_eq("1/2!", from_fp32(32'h3E2AAAAB, 7), 32'h3E2B);  // low half AAAB rounds up
    expect_eq("-inf", from_fp32(32'hFF800000, 7), 32'hFF80);
    expect_eq("tie to even down", from_fp32(32'h3F808000, 7), 32'h3F80);
    expect_eq("tie to even up", from_fp32(32'h3F818000, 7), 32'h3F82);
    expect_eq("fp32 unchanged", from_fp32(32'h3F867D5F, 23), 32'h3F867D5F);
    $display("TB_sienna_fmt_pkg: %0d errors", errs);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
