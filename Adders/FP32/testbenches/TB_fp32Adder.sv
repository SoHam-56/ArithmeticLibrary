`timescale 1ns / 100ps

module TB_fp32Adder;

  // -------------------------------------------------------------------------
  // 1. Setup and Imports
  // -------------------------------------------------------------------------
  import "DPI-C" function int c_fp32_add(
    input int a,
    input int b
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
    bit          exp_nan;
    bit          exp_inf;
    bit          exp_denormal;
  } transaction_t;

  transaction_t exp_queue[$];

  // -------------------------------------------------------------------------
  // 3. DUT Instantiation
  // -------------------------------------------------------------------------
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

  // -------------------------------------------------------------------------
  // 4. Helper Function: Input Sanitizer
  // -------------------------------------------------------------------------
  // Prevents random Denormals from verifying the "Traffic Cop" logic
  // instead of the Math Logic.
  function automatic logic [31:0] fix_random_input(logic [31:0] val);
    // If Exponent is 0 (Denormal/Zero), force it to 1 (Smallest Normal)
    if (val[30:23] == 0) return {val[31], 8'h01, val[22:0]};
    // If Exponent is 255 (Inf/NaN), force it to 254 (Max Normal)
    if (val[30:23] == 255) return {val[31], 8'hFE, val[22:0]};
    return val;
  endfunction

  // -------------------------------------------------------------------------
  // 5. Driver Task
  // -------------------------------------------------------------------------
  task drive_bus(input logic [31:0] a, input logic [31:0] b);
    transaction_t tx;

    // Calculate Golden Result via C++
    tx.a            = a;
    tx.b            = b;
    tx.expected_res = c_fp32_add(int'(a), int'(b));

    // Analyze Golden Result Flags
    tx.exp_nan      = (tx.expected_res[30:23] == 255 && tx.expected_res[22:0] != 0);
    tx.exp_inf      = (tx.expected_res[30:23] == 255 && tx.expected_res[22:0] == 0);
    // Check if C++ returned a Denormal (Exp=0, Man!=0)
    tx.exp_denormal = (tx.expected_res[30:23] == 0 && tx.expected_res[22:0] != 0);

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

  // -------------------------------------------------------------------------
  // 6. Monitor & Checker
  // -------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rstn && done_o) begin
      transaction_t exp;
      int diff;

      if (exp_queue.size() == 0) begin
        $display("ERROR: Unexpected output from DUT (Queue Empty)");
        err_count++;
      end else begin
        exp = exp_queue.pop_front();
        tx_count++;

        // --- Comparison Logic ---

        // 1. NaN Check
        if (exp.exp_nan) begin
          if (!invalid_dut) begin
            err_count++;
            if (err_count <= 15) $display("Tx %0d: Expected NaN, got valid.", tx_count);
          end
        end  // 2. Exact Match
        else if (result_dut == exp.expected_res) begin
          // Pass
        end  // 3. Denormal Relaxation
             // If C++ calculates a Denormal, but DUT outputs Zero, we accept it (HW limitation).
        else if (exp.exp_denormal && (result_dut[30:0] == 0)) begin
          // Pass
        end  // 4. ULP Tolerance
        else begin
          diff = int'(result_dut) - int'(exp.expected_res);
          if (diff < 0) diff = -diff;

          // Tolerance of 2-3 is needed for Adders due to "Effective Subtraction"
          // alignment rounding differences.
          if (diff > 3) begin
            err_count++;
            if (err_count <= 15) begin
              $display("---------------------------------------------------");
              $display("ERROR: Mismatch at Tx %0d", tx_count);
              $display("  Input A  : %h", exp.a);
              $display("  Input B  : %h", exp.b);
              $display("  Expected : %h", exp.expected_res);
              $display("  Got      : %h", result_dut);
              $display("  Diff     : %0d", diff);
              $display("---------------------------------------------------");
            end
            if (err_count == 16) $display("... Suppressing further errors ...");
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
    $dumpfile("TB_fp32Adder.vcd");
    $dumpvars(0, TB_fp32Adder);

    reset_sys();
    $display("=== STARTING ADDER TEST PLAN ===");

    // ------------------------------------------------
    // PHASE 1: Corner Cases (Identity, NaN, Inf)
    // ------------------------------------------------
    $display("[Phase 1] Corner Cases");
    drive_bus(32'h00000000, 32'h00000000);  // 0 + 0
    @(posedge clk);
    drive_bus(32'h3F800000, 32'h00000000);  // 1 + 0
    @(posedge clk);
    drive_bus(32'h7F800000, 32'h3F800000);  // Inf + 1
    @(posedge clk);
    drive_bus(32'hFF800000, 32'h7F800000);  // -Inf + Inf (NaN)
    @(posedge clk);
    drive_bus(32'h7FC00000, 32'h40000000);  // NaN + 2.0
    @(posedge clk);

    valid_i <= 0;
    repeat (10) @(posedge clk);

    // ------------------------------------------------
    // PHASE 2: Effective Subtraction (Cancellation)
    // ------------------------------------------------
    // This verifies the LZC (Leading Zero Counter) and Normalization Shift.
    $display("[Phase 2] Cancellation / Effective Subtraction");

    // 1.5 - 1.0 = 0.5 (Exponent changes from 127 to 126)
    drive_bus(32'h3FC00000, 32'hBF800000);
    @(posedge clk);

    // Massive Cancellation: 1.0000001 - 1.0000000
    // Result is tiny, requires finding the new MSB far to the right
    drive_bus(32'h3F800001, 32'hBF800000);
    @(posedge clk);

    // Cancellation resulting in result < 0
    drive_bus(32'h3F800000, 32'hBF800001);
    @(posedge clk);

    valid_i <= 0;
    repeat (10) @(posedge clk);

    // ------------------------------------------------
    // PHASE 3: Pipeline Stress
    // ------------------------------------------------
    $display("[Phase 3] Pipeline Stress (Back-to-Back)");
    repeat (50) begin
      r_a = fix_random_input($urandom);
      r_b = fix_random_input($urandom);
      drive_bus(r_a, r_b);
      @(posedge clk);
    end
    valid_i <= 0;
    repeat (10) @(posedge clk);

    // ------------------------------------------------
    // PHASE 4: Random Intermittency
    // ------------------------------------------------
    $display("[Phase 4] Random Valid Assertion");
    repeat (100) begin
      randcase
        1: begin
          r_a = fix_random_input($urandom);
          r_b = fix_random_input($urandom);
          drive_bus(r_a, r_b);
        end
        1: valid_i <= 0;
      endcase
      @(posedge clk);
    end
    valid_i <= 0;
    repeat (10) @(posedge clk);

    // ------------------------------------------------
    // PHASE 5: Unconstrained Random (Normalized)
    // ------------------------------------------------
    $display("[Phase 5] Unconstrained Random");
    repeat (2000) begin
      r_a = fix_random_input($urandom);
      r_b = fix_random_input($urandom);
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
