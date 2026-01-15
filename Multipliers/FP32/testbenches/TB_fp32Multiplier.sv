`timescale 1ns / 100ps

module TB_fp32Multiplier;

  import "DPI-C" function int c_fp32_multiply(
    input int a,
    input int b
  );

  localparam WIDTH = 32;
  localparam TEST_COUNT = 100;

  logic clk = 0;
  logic rstn;

  logic valid_i;
  logic [WIDTH-1:0] A_i, B_i;
  logic [WIDTH-1:0] result_dut;
  logic done_o;

  logic overflow_dut, underflow_dut, invalid_dut;

  logic [WIDTH-1:0] expected_queue[$];
  int error_count = 0;
  int transaction_count = 0;

  fp32Multiplier dut (
      .clk_i      (clk),
      .rstn_i     (rstn),
      .valid_i    (valid_i),
      .A          (A_i),
      .B          (B_i),
      .result_o   (result_dut),
      .done_o     (done_o),
      .overflow_o (overflow_dut),
      .underflow_o(underflow_dut),
      .invalid_o  (invalid_dut)
  );

  always #5 clk = ~clk;

  task system_reset();
    rstn = 0;
    valid_i = 0;
    A_i = 0;
    B_i = 0;
    expected_queue.delete();
    repeat (5) @(posedge clk);
    rstn = 1;
    repeat (2) @(posedge clk);
  endtask

  task drive_transaction(input logic [WIDTH-1:0] a, input logic [WIDTH-1:0] b);
    logic [WIDTH-1:0] golden_result;

    valid_i <= 1;
    A_i     <= a;
    B_i     <= b;

    golden_result = c_fp32_multiply(int'(a), int'(b));

    expected_queue.push_back(golden_result);
  endtask

  function bit is_close(input logic [31:0] golden, input logic [31:0] dut, input int tolerance);
    int diff;

    // 1. Check for NaN (Both must be NaN)
    // NaN definition: Exp=255, Mantissa!=0
    bit golden_nan, dut_nan;
    golden_nan = (golden[30:23] == 8'hFF) && (golden[22:0] != 0);
    dut_nan    = (dut[30:23] == 8'hFF)    && (dut[22:0] != 0);

    if (golden_nan && dut_nan) return 1;
    if (golden_nan != dut_nan) return 0;
    if (golden == dut) return 1;
    if (golden[30:0] == 0 && dut[30:0] == 0) return 1;
    if (golden[30:23] == 0 && golden[22:0] != 0 && dut[30:0] == 0) return 1;
    if (golden[31] != dut[31]) return 0;
    diff = int'(golden) - int'(dut);
    if (diff < 0) diff = -diff;

    return (diff <= tolerance);
  endfunction

  always @(posedge clk) begin
    if (rstn && done_o) begin
      logic [WIDTH-1:0] expected_val;

      if (expected_queue.size() > 0) begin
        expected_val = expected_queue.pop_front();
        transaction_count++;

        if (!is_close(expected_val, result_dut, 2)) begin
          // Variable for diff calculation
          int diff_debug;
          diff_debug = int'(expected_val) - int'(result_dut);
          if (diff_debug < 0) diff_debug = -diff_debug;

          $error("Mismatch at Tx %0d:", transaction_count);
          $display("  Input A  : %h", $past(A_i));
          $display("  Input B  : %h", $past(B_i));
          $display("  Expected : %h", expected_val);
          $display("  Got      : %h", result_dut);
          $display("  Diff     : %0d ULPs", diff_debug);

          if (overflow_dut) $display("  [Status: Overflow Detected]");
          if (underflow_dut) $display("  [Status: Underflow Detected]");
          if (invalid_dut) $display("  [Status: NaN Output]");

          error_count++;
        end
      end else begin
        $error("Unexpected done_o received while queue is empty!");
        error_count++;
      end
    end
  end

  logic [WIDTH-1:0] test_patterns[] = '{
      32'h00000000,
      32'h3F800000,
      32'hBF800000,
      32'h40000000,
      32'hC0000000,
      32'h3F000000,
      32'h41400000
  };

  initial begin
    
    system_reset();

    // directed tests
    foreach (test_patterns[i]) begin
      drive_transaction(test_patterns[i], 32'h3F800000);
      @(posedge clk);
    end
    foreach (test_patterns[i]) begin
      drive_transaction(test_patterns[i], test_patterns[i]);
      @(posedge clk);
    end

    valid_i <= 0;
    repeat (5) @(posedge clk);

    // random tests
    repeat (TEST_COUNT) begin
      drive_transaction($urandom, $urandom);
      @(posedge clk);
    end

    valid_i <= 0;
    wait (expected_queue.size() == 0);
    repeat (10) @(posedge clk);

    if (error_count == 0)
      $display("\nPASS: All %0d floating point vectors passed.\n", transaction_count);
    else $display("\nFAIL: %0d errors found.\n", error_count);
    $finish;
  end

  initial begin
    $dumpfile("TB_fp32Multiplier.vcd");
    $dumpvars(0, TB_fp32Multiplier);
  end
endmodule
