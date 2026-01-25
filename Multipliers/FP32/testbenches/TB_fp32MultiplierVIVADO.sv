`timescale 1ns / 100ps

module TB_fp32MultiplierVIVADO;

  localparam WIDTH = 32;
  localparam NUM_VECTORS = 10000;

  logic clk = 0;
  logic rstn = 0;
  always #5 clk = ~clk;

  logic valid_i;
  logic [WIDTH-1:0] A_i, B_i;
  logic [WIDTH-1:0] result_dut;
  logic done_o;
  logic overflow_dut, underflow_dut, invalid_dut;

  int err_count = 0;
  int tx_count = 0;

  // File Storage
  // Format: A(32) + B(32) + Res(32) + Flags(8) = 104 bits
  logic [103:0] test_vectors[0:NUM_VECTORS-1];

  typedef struct {
    logic [31:0] a;
    logic [31:0] b;
    logic [31:0] expected_res;

    // Expected Flags
    bit exp_overflow;
    bit exp_underflow;
    bit exp_invalid;
    bit exp_inexact;
  } transaction_t;

  transaction_t exp_queue[$];

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

  task drive_bus(input logic [31:0] a, input logic [31:0] b, input logic [31:0] golden_res,
                 input logic [7:0] golden_flags);
    transaction_t tx;

    tx.a = a;
    tx.b = b;
    tx.expected_res = golden_res;

    // Map Flags from File
    tx.exp_inexact = golden_flags[0];
    tx.exp_underflow = golden_flags[1];
    tx.exp_overflow = golden_flags[2];
    tx.exp_invalid = golden_flags[4];

    // Drive DUT
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

        // --- Check Result Data ---
        result_match = 0;

        // Allow Flush-to-Zero vs Denormal Mismatch (Handling +/- Zero)
        // Check if DUT result is Zero (ignoring sign bit) AND SoftFloat expected a Denormal (Exp=0)
        if (underflow_dut && (result_dut[30:0] == 0) && (exp.expected_res[30:23] == 0)) begin
          result_match = 1;
        end  // Check for NaN (Relaxed Payload check)
        else if ((exp.expected_res[30:23] == 255) && (exp.expected_res[22:0] != 0)) begin
          if ((result_dut[30:23] == 255) && (result_dut[22:0] != 0)) result_match = 1;
        end  // Exact Match
        else if (result_dut == exp.expected_res) begin
          result_match = 1;
        end  // Tolerance check (2 ULP)
        else begin
          diff = int'(result_dut) - int'(exp.expected_res);
          if (diff < 0) diff = -diff;
          if (diff <= 2) result_match = 1;
        end

        // --- Check Exception Flags ---
        flags_match = 1;
        if (overflow_dut != exp.exp_overflow) flags_match = 0;

        // Ignore underflow mismatch if we flushed to zero successfully
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

  logic [31:0] f_a, f_b, f_res;
  logic [7:0] f_flags;
  integer i;

  initial begin
    $display("Loading test vectors from 'vectors.mem'...");
    // Ensure vectors.mem is in the simulation directory
    $readmemh("vectors.mem", test_vectors);

    if (test_vectors[0] === 104'bx) begin
      $display("FATAL: Failed to load vectors.mem. Check file path!");
      $finish;
    end

    reset_sys();
    $display("=== STARTING VIVADO TEST PLAN ===");

    for (i = 0; i < NUM_VECTORS; i++) begin
      // Extract fields from the wide vector row
      {f_a, f_b, f_res, f_flags} = test_vectors[i];

      drive_bus(f_a, f_b, f_res, f_flags);

      @(posedge clk);
      // Optional: Add bubbles to test valid signal logic
      // if (i % 50 == 0) begin valid_i <= 0; repeat(2) @(posedge clk); end
    end

    valid_i <= 0;

    wait (exp_queue.size() == 0);
    repeat (20) @(posedge clk);

    if (err_count == 0) $display("\nSUCCESS: All %0d vectors passed!", tx_count);
    else $display("\nFAILURE: %0d errors detected.", err_count);

    $finish;
  end

endmodule
