`timescale 1ns / 100ps

module fp32Multiplier (
    input logic        clk_i,
    input logic        rstn_i,
    input logic        valid_i,
    input logic [31:0] A,
    input logic [31:0] B,

    output logic [31:0] result_o,
    output logic        done_o,

    // Status Flags
    output logic overflow_o,   // High if result clamped to Infinity
    output logic underflow_o,  // High if result flushed to Zero
    output logic invalid_o     // High if result is NaN
);

  // Latency Tuning: For unsigned multiplication engine implementations
  localparam INT_SYNC_DELAY = 1;

  // -------------------------------------------------------------------------
  // Stage 1: Input Unpacking & Special Case Detection
  // -------------------------------------------------------------------------
  logic s1_valid;
  logic s1_sign_a, s1_sign_b;
  logic [7:0] s1_exp_a, s1_exp_b;
  logic [23:0] s1_man_a, s1_man_b;

  // Special Case Flags
  logic s1_is_zero;  // Result will be zero (if not NaN)
  logic s1_result_is_nan;  // Result will be NaN

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s1_valid               <= 0;
      {s1_sign_a, s1_sign_b} <= 0;
      {s1_exp_a, s1_exp_b}   <= 0;
      {s1_man_a, s1_man_b}   <= 0;
      s1_is_zero             <= 0;
      s1_result_is_nan       <= 0;
    end else begin
      s1_valid <= valid_i;

      if (valid_i) begin
        // --- 1. Classification ---
        automatic logic zero_a, zero_b;
        automatic logic inf_a, inf_b;
        automatic logic nan_a, nan_b;

        zero_a = (~|A[30:0]);
        zero_b = (~|B[30:0]);
        inf_a  = (A[30:23] == 8'hFF) && (A[22:0] == 0);
        inf_b  = (B[30:23] == 8'hFF) && (B[22:0] == 0);
        nan_a  = (A[30:23] == 8'hFF) && (A[22:0] != 0);
        nan_b  = (B[30:23] == 8'hFF) && (B[22:0] != 0);

        // --- 2. NaN Detection Logic ---
        // Result is NaN if: Input is NaN OR (Infinity * Zero)
        if (nan_a || nan_b || (inf_a && zero_b) || (zero_a && inf_b)) begin
          s1_result_is_nan <= 1'b1;
          s1_is_zero       <= 1'b0;  // NaN overrides Zero
        end  // --- 3. Zero Detection Logic ---
        else if (zero_a || zero_b) begin
          s1_result_is_nan <= 1'b0;
          s1_is_zero       <= 1'b1;
        end  // --- 4. Normal Case ---
        else begin
          s1_result_is_nan <= 1'b0;
          s1_is_zero       <= 1'b0;
        end

        // --- 5. Latch Data ---
        // If Zero, we clean the pipeline to save power, otherwise load inputs
        if (zero_a || zero_b) begin
          s1_sign_a <= 0;
          s1_sign_b <= 0;
          s1_exp_a  <= 0;
          s1_exp_b  <= 0;
          s1_man_a  <= 0;
          s1_man_b  <= 0;
        end else begin
          s1_sign_a <= A[31];
          s1_sign_b <= B[31];
          s1_exp_a  <= A[30:23];
          s1_exp_b  <= B[30:23];
          s1_man_a  <= {1'b1, A[22:0]};
          s1_man_b  <= {1'b1, B[22:0]};
        end
      end
    end
  end

  // -------------------------------------------------------------------------
  // Stage 2A: Mantissa Path (Karatsuba)
  // -------------------------------------------------------------------------
  logic        mult_valid_out;
  logic [47:0] raw_product;

  karatsubaUnsigned #(
      .WIDTH(24)
  ) u_karatsuba (
      .clk_i         (clk_i),
      .rstn_i        (rstn_i),
      .valid_i       (s1_valid),
      .multiplicand_i(s1_man_a),
      .multiplier_i  (s1_man_b),
      .valid_o       (mult_valid_out),
      .product_o     (raw_product)
  );

  // -------------------------------------------------------------------------
  // Stage 2B: Exponent Path (Pipelined Adders)
  // -------------------------------------------------------------------------
  logic [3:0] exp_valid_pipe;
  logic       pipe_carry     [0:3];
  logic [9:0] pipe_sum       [0:3];
  logic pipe_sign_a[0:3], pipe_sign_b[0:3];
  logic pipe_zero[0:3];
  logic pipe_nan [0:3];  // <--- Pipelined NaN Flag
  logic [7:0] pipe_exp_a[0:3], pipe_exp_b[0:3];

  // Adder Slice 1: Bits [1:0]
  always_ff @(posedge clk_i) begin
    exp_valid_pipe[0] <= s1_valid;
    if (s1_valid) begin
      {pipe_carry[0], pipe_sum[0][1:0]} <= s1_exp_a[1:0] + s1_exp_b[1:0];
      pipe_sum[0][9:2] <= 0;
      pipe_sign_a[0] <= s1_sign_a;
      pipe_sign_b[0] <= s1_sign_b;
      pipe_zero[0]   <= s1_is_zero;
      pipe_nan[0]    <= s1_result_is_nan;
      pipe_exp_a[0]  <= s1_exp_a;
      pipe_exp_b[0]  <= s1_exp_b;
    end
  end

  // Adder Slice 2: Bits [3:2]
  always_ff @(posedge clk_i) begin
    exp_valid_pipe[1] <= exp_valid_pipe[0];
    if (exp_valid_pipe[0]) begin
      pipe_sum[1][1:0]                  <= pipe_sum[0][1:0];
      {pipe_carry[1], pipe_sum[1][3:2]} <= pipe_exp_a[0][3:2] + pipe_exp_b[0][3:2] + pipe_carry[0];
      pipe_sum[1][9:4]                  <= 0;
      pipe_sign_a[1]                    <= pipe_sign_a[0];
      pipe_sign_b[1]                    <= pipe_sign_b[0];
      pipe_zero[1]                      <= pipe_zero[0];
      pipe_nan[1]                       <= pipe_nan[0];
      pipe_exp_a[1]                     <= pipe_exp_a[0];
      pipe_exp_b[1]                     <= pipe_exp_b[0];
    end
  end

  // Adder Slice 3: Bits [5:4]
  always_ff @(posedge clk_i) begin
    exp_valid_pipe[2] <= exp_valid_pipe[1];
    if (exp_valid_pipe[1]) begin
      pipe_sum[2][3:0]                  <= pipe_sum[1][3:0];
      {pipe_carry[2], pipe_sum[2][5:4]} <= pipe_exp_a[1][5:4] + pipe_exp_b[1][5:4] + pipe_carry[1];
      pipe_sum[2][9:6]                  <= 0;
      pipe_sign_a[2]                    <= pipe_sign_a[1];
      pipe_sign_b[2]                    <= pipe_sign_b[1];
      pipe_zero[2]                      <= pipe_zero[1];
      pipe_nan[2]                       <= pipe_nan[1];
      pipe_exp_a[2]                     <= pipe_exp_a[1];
      pipe_exp_b[2]                     <= pipe_exp_b[1];
    end
  end

  // Adder Slice 4: Bits [7:6]
  always_ff @(posedge clk_i) begin
    exp_valid_pipe[3] <= exp_valid_pipe[2];
    if (exp_valid_pipe[2]) begin
      pipe_sum[3][5:0] <= pipe_sum[2][5:0];
      {pipe_sum[3][9:8], pipe_sum[3][7:6]} <= {2'b0, pipe_exp_a[2][7:6]} + {2'b0, pipe_exp_b[2][7:6]} + pipe_carry[2];
      pipe_sign_a[3] <= pipe_sign_a[2];
      pipe_sign_b[3] <= pipe_sign_b[2];
      pipe_zero[3] <= pipe_zero[2];
      pipe_nan[3] <= pipe_nan[2];  // Pass NaN
    end
  end

  // Bias Subtraction Block (Handles Exceptions)
  logic       exp_calc_sign;
  logic       exp_calc_zero;
  logic       exp_calc_inf;  // Flag for Overflow
  logic       exp_calc_underflow;  // Flag for Underflow
  logic       exp_calc_nan;  // Flag for NaN
  logic [9:0] exp_calc_result;

  always_ff @(posedge clk_i) begin
    if (exp_valid_pipe[3]) begin
      exp_calc_sign      <= pipe_sign_a[3] ^ pipe_sign_b[3];
      exp_calc_nan       <= pipe_nan[3];

      exp_calc_inf       <= 0;
      exp_calc_underflow <= 0;
      exp_calc_zero      <= 0;

      // PRIORITY 1: NaN (Pass through)
      if (pipe_nan[3]) exp_calc_result <= 0;

      // PRIORITY 2: Input Zero
      else if (pipe_zero[3]) begin
        exp_calc_zero   <= 1'b1;
        exp_calc_result <= 0;
      end  

      // PRIORITY 3: Overflow Check (Infinity)
      // Max Exp = 254. Bias = 127. Threshold = 382.
      else if (pipe_sum[3] >= 10'd382) begin
        exp_calc_inf    <= 1'b1;
        exp_calc_result <= 10'd255; // Set to Max Exponent
      end  

      // PRIORITY 4: Underflow Check (Flush to Zero)
      else if (pipe_sum[3] < 10'd127) begin
        exp_calc_underflow <= 1'b1;
        exp_calc_zero      <= 1'b1;
        exp_calc_result    <= 0;
      end  

      // PRIORITY 5: Normal Calculation
      else
        exp_calc_result <= pipe_sum[3] - 10'd127;
    end
  end

  // -------------------------------------------------------------------------
  // Stage 3: Alignment Delay Line
  // -------------------------------------------------------------------------
  typedef struct packed {
    logic       is_nan;
    logic       is_inf;
    logic       is_underflow;
    logic       zero;
    logic       sign;
    logic [9:0] exp;
  } meta_data_t;
  meta_data_t sync_data;

  generate
    if (INT_SYNC_DELAY > 0) begin : gen_delay
      meta_data_t delay_regs[0:INT_SYNC_DELAY-1];
      always_ff @(posedge clk_i) begin
        delay_regs[0].is_nan       <= exp_calc_nan;
        delay_regs[0].is_inf       <= exp_calc_inf;
        delay_regs[0].is_underflow <= exp_calc_underflow;
        delay_regs[0].zero         <= exp_calc_zero;
        delay_regs[0].sign         <= exp_calc_sign;
        delay_regs[0].exp          <= exp_calc_result;
        for (int i = 1; i < INT_SYNC_DELAY; i++) delay_regs[i] <= delay_regs[i-1];
      end
      assign sync_data = delay_regs[INT_SYNC_DELAY-1];
    end else begin : gen_wire
      assign sync_data = {
        exp_calc_nan,
        exp_calc_inf,
        exp_calc_underflow,
        exp_calc_zero,
        exp_calc_sign,
        exp_calc_result
      };
    end
  endgenerate

  // -------------------------------------------------------------------------
  // Stage 4: Normalization & Packing
  // -------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      result_o    <= 0;
      done_o      <= 0;
      overflow_o  <= 0;
      underflow_o <= 0;
      invalid_o   <= 0;
    end else begin
      done_o <= mult_valid_out;

      if (mult_valid_out) begin

        overflow_o  <= sync_data.is_inf;
        underflow_o <= sync_data.is_underflow;
        invalid_o   <= sync_data.is_nan;  // <--- NEW

        // PRIORITY 1: NaN (Highest Priority)
        if (sync_data.is_nan) result_o <= 32'h7FC00000;  // Standard Canonical NaN

        // PRIORITY 2: Infinity (Overflow)
        else if (sync_data.is_inf) result_o <= {sync_data.sign, 8'hFF, 23'd0};  // +/- Infinity

        // PRIORITY 3: Zero (Input Zero OR Underflow)
        else if (sync_data.zero) result_o <= 32'd0;

        // PRIORITY 4: Normal Result
        else begin
          automatic logic [ 7:0] final_exp;
          automatic logic [22:0] final_man;

          if (raw_product[47]) begin
            final_man = raw_product[46:24];
            final_exp = sync_data.exp[7:0] + 1'b1;
          end else begin
            final_man = raw_product[45:23];
            final_exp = sync_data.exp[7:0];
          end
          result_o <= {sync_data.sign, final_exp, final_man};
        end
      end else begin
        // Clean flags when invalid to keep waveforms clean
        overflow_o  <= 0;
        underflow_o <= 0;
        invalid_o   <= 0;
      end
    end
  end

endmodule
