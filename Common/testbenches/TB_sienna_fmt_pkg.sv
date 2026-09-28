`timescale 1ns / 100ps

// Checks sienna_fmt_pkg: supported formats, unit latencies, and constants narrowed from fp32.
module TB_sienna_fmt_pkg;
  import sienna_fmt_pkg::*;
  int errs = 0;

  task automatic expect_eq(input string what, input longint got, input longint want);
    if (got != want) begin
      errs++;
      $display("[FAIL] %s: got %0h, want %0h", what, got, want);
    end
  endtask

  initial begin
    expect_eq("is_fp32(8,23)", is_fp32(8, 23), 1);
    expect_eq("is_fp32(8,7)", is_fp32(8, 7), 0);
    expect_eq("supported(8,7)", supported(8, 7), 1);
    expect_eq("supported(5,10)", supported(5, 10), 0);
    expect_eq("mul_lat(8,23)", mul_lat(8, 23), 8);
    expect_eq("mul_lat(8,7)", mul_lat(8, 7), 3);
    expect_eq("add_lat(8,23)", add_lat(8, 23), 5);
    expect_eq("add_lat(8,7)", add_lat(8, 7), 5);
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
