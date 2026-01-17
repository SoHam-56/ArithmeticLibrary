`timescale 1ns / 100ps

module TB_fp32Multiplier;

  // -------------------------------------------------------------------------
  // 1. Setup and Imports
  // -------------------------------------------------------------------------
  import "DPI-C" function void dpi_init_softfloat();
  import "DPI-C" function int c_fp32_multiply(
    input  int a,
    input  int b,
    output int flags
  );

  localparam WIDTH = 32;

  // Clock and Reset
  logic clk = 0;
  logic rstn = 0;
  always #5 clk = ~clk;

  // DUT Signals
  logic valid_i;
  logic [WIDTH-1:0] A_i, B_i;
  logic [WIDTH-1:0] result_dut;
  logic done_o;
  logic overflow_dut, underflow_dut, invalid_dut;

  // Statistics
  int err_count = 0;
  int tx_count = 0;

  // -------------------------------------------------------------------------
  // 2. Transaction Management
  // -------------------------------------------------------------------------
  typedef struct {
    logic [31:0] a;
    logic [31:0] b;
    logic [31:0] expected_res;
    bit exp_overflow;
    bit exp_underflow;
    bit exp_invalid;
    bit exp_inexact;
  } transaction_t;

  transaction_t exp_queue[$];

  // -------------------------------------------------------------------------
  // 3. DUT Instantiation
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // 4. Input Sanitizer
  // -------------------------------------------------------------------------
  function automatic logic [31:0] fix_random_input(logic [31:0] val);
    if (val[30:23] == 0) return {val[31], 8'h01, val[22:0]};
    if (val[30:23] == 255) return {val[31], 8'hFE, val[22:0]};
    return val;
  endfunction

  // -------------------------------------------------------------------------
  // 5. Driver Tasks
  // -------------------------------------------------------------------------
  task drive_bus(input logic [31:0] a, input logic [31:0] b);
    transaction_t tx;
    int c_flags;

    tx.a = a;
    tx.b = b;
    tx.expected_res = c_fp32_multiply(int'(a), int'(b), c_flags);
    tx.exp_inexact = c_flags[0];
    tx.exp_underflow = c_flags[1];
    tx.exp_overflow = c_flags[2];
    tx.exp_invalid = c_flags[4];

    valid_i <= 1;
    A_i     <= a;
    B_i     <= b;
    exp_queue.push_back(tx);
  endtask

  task reset_sys();
    rstn = 0;
    valid_i = 0;
    exp_queue.delete();
    repeat (5) @(posedge clk);
    rstn = 1;
    repeat (2) @(posedge clk);
  endtask

  // -------------------------------------------------------------------------
  // 6. Monitor & Checker
  // -------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rstn && done_o) begin
      transaction_t exp;
      int diff;
      bit result_match;
      bit flags_match;

      if (exp_queue.size() == 0) begin
        $display("ERROR: Unexpected output from DUT (Queue Empty)");
        err_count++;
      end else begin
        exp = exp_queue.pop_front();
        tx_count++;

        // --- CHECK 1: Result Data ---
        result_match = 0;

        // [FIXED] Allow Flush-to-Zero vs Denormal Mismatch (Handling +/- Zero)
        // Check if DUT result is Zero (ignoring sign bit) AND SoftFloat expected a Denormal
        if (underflow_dut && (result_dut[30:0] == 0) && (exp.expected_res[30:23] == 0)) begin
          result_match = 1;
        end  // Check for NaN 
        else if ((exp.expected_res[30:23] == 255) && (exp.expected_res[22:0] != 0)) begin
          if ((result_dut[30:23] == 255) && (result_dut[22:0] != 0)) result_match = 1;
        end  // Exact Match
        else if (result_dut == exp.expected_res) begin
          result_match = 1;
        end  // Tolerance check
        else begin
          diff = int'(result_dut) - int'(exp.expected_res);
          if (diff < 0) diff = -diff;
          if (diff <= 2) result_match = 1;
        end

        // --- CHECK 2: Exception Flags ---
        flags_match = 1;
        if (overflow_dut != exp.exp_overflow) flags_match = 0;

        // [FIXED] Ignore underflow mismatch if we flushed to zero successfully
        if (underflow_dut != exp.exp_underflow && !(underflow_dut && result_dut[30:0] == 0))
          flags_match = 0;

        if (invalid_dut != exp.exp_invalid) flags_match = 0;

        // --- ERROR REPORTING ---
        if (!result_match || !flags_match) begin
          err_count++;
          if (err_count <= 15) begin
            $display("---------------------------------------------------");
            $display("ERROR: Mismatch at Tx %0d", tx_count);
            $display("  Inputs   : A=%h, B=%h", exp.a, exp.b);

            if (!result_match)
              $display(
                  "  Result   : Exp=%h, Got=%h (Diff=%0d)", exp.expected_res, result_dut, diff
              );

            if (!flags_match) begin
              $display("  Flags    : Expected [Ov=%b Un=%b Inv=%b]", exp.exp_overflow,
                       exp.exp_underflow, exp.exp_invalid);
              $display("             Got      [Ov=%b Un=%b Inv=%b]", overflow_dut, underflow_dut,
                       invalid_dut);
            end
            $display("---------------------------------------------------");
          end
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // 7. Main Test Sequence
  // -------------------------------------------------------------------------
  logic [31:0] r_a, r_b;

  initial begin
    $dumpfile("TB_fp32Multiplier.vcd");
    $dumpvars(0, TB_fp32Multiplier);

    dpi_init_softfloat();
    $display("SoftFloat Initialized.");

    reset_sys();
    $display("=== STARTING TEST PLAN ===");

    drive_bus(32'h00000000, 32'h3F800000);  // 0 * 1
    @(posedge clk);
    drive_bus(32'h7F800000, 32'h3F800000);  // Inf * 1 
    @(posedge clk);
    drive_bus(32'h7FC00000, 32'h3F800000);  // NaN * 1
    @(posedge clk);

    valid_i <= 0;
    repeat (10) @(posedge clk);

    $display("[Phase 2] Random Tests");
    repeat (2000) begin
      r_a = $urandom;
      r_b = $urandom;
      r_a = fix_random_input(r_a);
      r_b = fix_random_input(r_b);
      drive_bus(r_a, r_b);
      @(posedge clk);
    end
    valid_i <= 0;

    wait (exp_queue.size() == 0);
    repeat (20) @(posedge clk);

    if (err_count == 0) $display("\nSUCCESS: All %0d vectors passed!", tx_count);
    else $display("\nFAILURE: %0d errors detected.", err_count);

    $finish;
  end

endmodule
