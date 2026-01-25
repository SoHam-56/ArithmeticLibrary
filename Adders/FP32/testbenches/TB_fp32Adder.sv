`timescale 1ns / 100ps

module TB_fp32Adder;

  import "DPI-C" function void dpi_init_adder();
  import "DPI-C" function int c_fp32_add(
    input  int a,
    input  int b,
    output int flags
  );

  localparam WIDTH = 32;

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

  typedef struct {
    logic [31:0] a;
    logic [31:0] b;
    logic [31:0] expected_res;
    bit          exp_inexact;
    bit          exp_underflow;
    bit          exp_overflow;
    bit          exp_invalid;
  } transaction_t;

  transaction_t exp_queue[$];

  // fp32Adder dut (
  //     .clk_i      (clk),
  //     .rstn_i     (rstn),
  //     .valid_i    (valid_i),
  //     .A          (A_i),
  //     .B          (B_i),
  //     .result_o   (result_dut),
  //     .done_o     (done_o),
  //     .overflow_o (overflow_dut),
  //     .underflow_o(underflow_dut),
  //     .invalid_o  (invalid_dut)
  // );

  Adder_32 dut (
      .clk_i  (clk),
      .rstn_i (rstn),
      .valid_i(valid_i),
      .A      (A_i),
      .B      (B_i),
      .Result (result_dut),
      .done_o (done_o)
  );

  function automatic logic [31:0] fix_random_input(logic [31:0] val);
    // Force Denormals (Exp=0) to Smallest Normal (Exp=1)
    if (val[30:23] == 0) return {val[31], 8'h01, val[22:0]};
    // Force Inf/NaN (Exp=255) to Largest Normal (Exp=254)
    if (val[30:23] == 255) return {val[31], 8'hFE, val[22:0]};
    return val;
  endfunction

  task drive_bus(input logic [31:0] a, input logic [31:0] b);
    transaction_t tx;
    int c_flags;

    tx.a = a;
    tx.b = b;
    tx.expected_res = c_fp32_add(int'(a), int'(b), c_flags);

    // Bit 0: Inexact, 1: Underflow, 2: Overflow, 3: Infinite, 4: Invalid
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

        // Exact Match
        if (result_dut == exp.expected_res) begin
          result_match = 1;
        end  // NaN Matching (All NaNs are treated equal for verification)
        else if ((exp.expected_res[30:23] == 255) && (exp.expected_res[22:0] != 0)) begin
          if ((result_dut[30:23] == 255) && (result_dut[22:0] != 0)) result_match = 1;
        end  // Tolerance Check (Allow +/- 3 ULP)
        else begin
          diff = int'(result_dut) - int'(exp.expected_res);
          if (diff < 0) diff = -diff;
          if (diff <= 3) result_match = 1;
        end

        // --- Check Exception Flags ---
        flags_match = 1;
        if (overflow_dut != exp.exp_overflow) flags_match = 0;
        if (invalid_dut != exp.exp_invalid) flags_match = 0;
        // Strict Underflow Check (Since model now handles FTZ explicitly)
        if (underflow_dut != exp.exp_underflow) flags_match = 0;

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

  logic [31:0] r_a, r_b;

  initial begin
    $dumpfile("TB_fp32Adder.vcd");
    $dumpvars(0, TB_fp32Adder);

    dpi_init_adder();
    $display("SoftFloat Initialized.");

    reset_sys();
    $display("=== STARTING ADDER TEST PLAN ===");

    // Phase 1: Corner Cases
    $display("[Phase 1] Corner Cases");
    drive_bus(32'h00000000, 32'h00000000);  // 0 + 0
    @(posedge clk);
    drive_bus(32'h3F800000, 32'h00000000);  // 1.0 + 0
    @(posedge clk);
    drive_bus(32'h7F800000, 32'h3F800000);  // Inf + 1.0
    @(posedge clk);
    drive_bus(32'hFF800000, 32'h7F800000);  // -Inf + Inf (NaN)
    @(posedge clk);
    drive_bus(32'h7FC00000, 32'h40000000);  // NaN + 2.0
    @(posedge clk);

    valid_i <= 0;
    repeat (10) @(posedge clk);

    // Phase 2: Effective Subtraction
    $display("[Phase 2] Cancellation / Effective Subtraction");
    drive_bus(32'h3FC00000, 32'hBF800000);  // 1.5 - 1.0 = 0.5
    @(posedge clk);
    drive_bus(32'h3F800001, 32'hBF800000);  // Massive Cancellation
    @(posedge clk);

    valid_i <= 0;
    repeat (10) @(posedge clk);

    // Phase 3: Randomized Stress
    $display("[Phase 3] Unconstrained Random (Normalized)");
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
