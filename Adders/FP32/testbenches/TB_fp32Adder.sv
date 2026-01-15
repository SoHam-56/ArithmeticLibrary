`timescale 1ns / 100ps

module TB_fp32Adder;

  import "DPI-C" function int c_fp32_add(
    input int a,
    input int b
  );

  localparam WIDTH = 32;
  localparam TEST_COUNT = 1000;

  logic clk = 0;
  logic rstn;

  logic valid_i;
  logic [WIDTH-1:0] A_i, B_i;

  logic [WIDTH-1:0] result_dut;
  logic done_o;
  logic overflow_dut, underflow_dut, invalid_dut;

  typedef struct {
    logic [WIDTH-1:0] expected;
    logic [WIDTH-1:0] a_stim;
    logic [WIDTH-1:0] b_stim;
  } transaction_t;

  transaction_t expected_queue[$];

  int error_count = 0;
  int transaction_count = 0;

  fp32Adder dut (
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
    transaction_t trans;

    valid_i <= 1;
    A_i     <= a;
    B_i     <= b;

    trans.expected = c_fp32_add(int'(a), int'(b));
    trans.a_stim   = a;
    trans.b_stim   = b;

    expected_queue.push_back(trans);
  endtask

  function bit is_close(input logic [31:0] golden, input logic [31:0] dut, input int tolerance);
    int diff;
    bit golden_nan, dut_nan;
    bit golden_inf, dut_inf;

    golden_nan = (golden[30:23] == 8'hFF) && (golden[22:0] != 0);
    dut_nan    = (dut[30:23] == 8'hFF)    && (dut[22:0] != 0);

    if (golden_nan && dut_nan) return 1;
    if (golden_nan != dut_nan) return 0;

    golden_inf = (golden[30:23] == 8'hFF) && (golden[22:0] == 0);
    dut_inf    = (dut[30:23] == 8'hFF)    && (dut[22:0] == 0);
    if (golden_inf && dut_inf) return (golden[31] == dut[31]);
    if (golden == dut) return 1;
    if (golden[30:0] == 0 && dut[30:0] == 0) return 1;
    if (golden[31] != dut[31]) return 0;
    diff = int'(golden) - int'(dut);
    if (diff < 0) diff = -diff;

    return (diff <= tolerance);
  endfunction

  always @(posedge clk) begin
    if (rstn && done_o) begin
      transaction_t t;

      if (expected_queue.size() > 0) begin
        t = expected_queue.pop_front();
        transaction_count++;

        // Allow 2 ULP tolerance for rounding differences between C and HW
        if (!is_close(t.expected, result_dut, 2)) begin
          int diff_debug;
          diff_debug = int'(t.expected) - int'(result_dut);
          if (diff_debug < 0) diff_debug = -diff_debug;

          $error("\n[ERROR] Mismatch at Tx %0d:", transaction_count);
          $display("  Input A      : %h (%e)", t.a_stim, $bitstoshortreal(t.a_stim));
          $display("  Input B      : %h (%e)", t.b_stim, $bitstoshortreal(t.b_stim));
          $display("  Expected     : %h", t.expected);
          $display("  Got          : %h", result_dut);
          $display("  Diff (ULPs)  : %0d", diff_debug);

          if (overflow_dut) $display("  [Flag] Overflow");
          if (underflow_dut) $display("  [Flag] Underflow");
          if (invalid_dut) $display("  [Flag] Invalid (NaN)");

          error_count++;
        end
      end else begin
        $error("Unexpected 'done_o' received while queue is empty!");
        error_count++;
      end
    end
  end

  logic [WIDTH-1:0] test_vectors[] = '{
      32'h00000000,  // 0.0
      32'h3F800000,  // 1.0
      32'h40000000,  // 2.0
      32'hBF800000,  // -1.0
      32'hC0000000,  // -2.0
      32'h7F800000,  // +Inf
      32'hFF800000,  // -Inf
      32'h7FC00000,  // NaN
      32'h33D6BF95,  // Very small number
      32'h7149F2CA  // Large number
  };

  initial begin
    system_reset();

    $display("--- Starting Directed Tests ---");
    foreach (test_vectors[i]) begin
      foreach (test_vectors[j]) begin
        drive_transaction(test_vectors[i], test_vectors[j]);
        @(posedge clk);
      end
    end

    valid_i <= 0;
    repeat (10) @(posedge clk);

    $display("--- Starting Random Tests ---");
    repeat (TEST_COUNT) begin
      drive_transaction($urandom, $urandom);
      @(posedge clk);
    end

    valid_i <= 0;

    wait (expected_queue.size() == 0);
    repeat (10) @(posedge clk);

    if (error_count == 0)
      $display("\nPASS: All %0d transactions passed successfully.\n", transaction_count);
    else $display("\nFAIL: %0d errors found.\n", error_count);

    $finish;
  end

  initial begin
    $dumpfile("TB_fp32Adder.vcd");
    $dumpvars(0, TB_fp32Adder);
  end

endmodule
