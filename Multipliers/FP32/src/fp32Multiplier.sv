`timescale 1ns / 100ps

module fp32Multiplier (
    input logic        clk_i,
    input logic        rstn_i,
    input logic        valid_i,
    input logic [31:0] A,
    input logic [31:0] B,

    output logic [31:0] result_o,
    output logic        done_o,

    output logic overflow_o,   // High only on Finite -> Infinite
    output logic underflow_o,  // High on Flush-to-Zero
    output logic invalid_o     // High on 0*Inf or sNaN input
);

  localparam INT_SYNC_DELAY = 1;

  logic s1_valid;
  logic s1_sign_a, s1_sign_b;
  logic [7:0] s1_exp_a, s1_exp_b;
  logic [23:0] s1_man_a, s1_man_b;

  // Classification Flags
  logic s1_is_input_zero;
  logic s1_is_input_inf;
  logic s1_is_input_nan;
  logic s1_is_invalid_op;
  logic s1_is_snan;

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s1_valid               <= 0;
      {s1_sign_a, s1_sign_b} <= 0;
      {s1_exp_a, s1_exp_b}   <= 0;
      {s1_man_a, s1_man_b}   <= 0;
      s1_is_input_zero       <= 0;
      s1_is_input_inf        <= 0;
      s1_is_input_nan        <= 0;
      s1_is_invalid_op       <= 0;
      s1_is_snan             <= 0;
    end else begin
      s1_valid <= valid_i;

      if (valid_i) begin
        logic zero_a, zero_b;
        logic inf_a, inf_b;
        logic nan_a, nan_b;
        logic snan_a, snan_b;

        // If Exponent is 0, treat as Zero even if mantissa is non-zero.
        zero_a = (A[30:23] == 0);
        zero_b = (B[30:23] == 0);

        inf_a  = (A[30:23] == 8'hFF) && (A[22:0] == 0);
        inf_b  = (B[30:23] == 8'hFF) && (B[22:0] == 0);
        nan_a  = (A[30:23] == 8'hFF) && (A[22:0] != 0);
        nan_b  = (B[30:23] == 8'hFF) && (B[22:0] != 0);

        // Signaling NaN Detection (MSB of Mantissa is 0)
        snan_a = nan_a && (A[22] == 0);
        snan_b = nan_b && (B[22] == 0);

        s1_is_input_nan  <= nan_a || nan_b;
        s1_is_snan       <= snan_a || snan_b;

        // Invalid Op: Inf * Zero OR Signaling NaN
        s1_is_invalid_op <= (inf_a && zero_b) || (zero_a && inf_b);

        s1_is_input_inf  <= (inf_a || inf_b);
        s1_is_input_zero <= (zero_a || zero_b);

        if (zero_a || zero_b || inf_a || inf_b || nan_a || nan_b) begin
          s1_sign_a <= A[31];
          s1_sign_b <= B[31];
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

  logic [3:0] exp_valid_pipe;
  logic       pipe_carry     [0:3];
  logic [9:0] pipe_sum       [0:3];
  logic pipe_sign_a[0:3], pipe_sign_b[0:3];

  logic pipe_in_zero[0:3];
  logic pipe_in_inf [0:3];
  logic pipe_in_nan [0:3];
  logic pipe_inv_op [0:3];
  logic pipe_in_snan[0:3];  // Pipeline sNaN flag

  logic [7:0] pipe_exp_a[0:3], pipe_exp_b[0:3];

  // --- Adder Slice 0 (Bits 1:0) ---
  always_ff @(posedge clk_i) begin
    exp_valid_pipe[0] <= s1_valid;
    if (s1_valid) begin
      {pipe_carry[0], pipe_sum[0][1:0]} <= s1_exp_a[1:0] + s1_exp_b[1:0];
      pipe_sum[0][9:2] <= 0;
      pipe_sign_a[0]   <= s1_sign_a;
      pipe_sign_b[0]   <= s1_sign_b;

      pipe_in_zero[0]  <= s1_is_input_zero;
      pipe_in_inf[0]   <= s1_is_input_inf;
      pipe_in_nan[0]   <= s1_is_input_nan;
      pipe_inv_op[0]   <= s1_is_invalid_op;
      pipe_in_snan[0]  <= s1_is_snan;

      pipe_exp_a[0]    <= s1_exp_a;
      pipe_exp_b[0]    <= s1_exp_b;
    end
  end

  // --- Adder Slices 1 & 2 (Bits 3:2, 5:4) ---
  genvar i;
  generate
    for (i = 1; i < 3; i++) begin : exp_pipe_mid
      always_ff @(posedge clk_i) begin
        exp_valid_pipe[i] <= exp_valid_pipe[i-1];
        if (exp_valid_pipe[i-1]) begin
          pipe_sign_a[i] <= pipe_sign_a[i-1];
          pipe_sign_b[i] <= pipe_sign_b[i-1];
          pipe_in_zero[i] <= pipe_in_zero[i-1];
          pipe_in_inf[i] <= pipe_in_inf[i-1];
          pipe_in_nan[i] <= pipe_in_nan[i-1];
          pipe_inv_op[i] <= pipe_inv_op[i-1];
          pipe_in_snan[i] <= pipe_in_snan[i-1];

          pipe_sum[i][(i*2)-1 : 0] <= pipe_sum[i-1][(i*2)-1 : 0];

          {pipe_carry[i], pipe_sum[i][(i*2)+1 : (i*2)]} <= 
              pipe_exp_a[i-1][(i*2)+1 : (i*2)] + 
              pipe_exp_b[i-1][(i*2)+1 : (i*2)] + 
              pipe_carry[i-1];

          pipe_exp_a[i] <= pipe_exp_a[i-1];
          pipe_exp_b[i] <= pipe_exp_b[i-1];
        end
      end
    end
  endgenerate

  // --- Adder Slice 3 (Bits 7:6 - Final) ---
  always_ff @(posedge clk_i) begin
    exp_valid_pipe[3] <= exp_valid_pipe[2];
    if (exp_valid_pipe[2]) begin
      pipe_sign_a[3] <= pipe_sign_a[2];
      pipe_sign_b[3] <= pipe_sign_b[2];
      pipe_in_zero[3] <= pipe_in_zero[2];
      pipe_in_inf[3] <= pipe_in_inf[2];
      pipe_in_nan[3] <= pipe_in_nan[2];
      pipe_inv_op[3] <= pipe_inv_op[2];
      pipe_in_snan[3] <= pipe_in_snan[2];

      pipe_sum[3][5:0] <= pipe_sum[2][5:0];

      {pipe_sum[3][9:8], pipe_sum[3][7:6]} <= 
              {2'b0, pipe_exp_a[2][7:6]} + 
              {2'b0, pipe_exp_b[2][7:6]} + 
              pipe_carry[2];
    end
  end

  // Bias Subtraction & Exception Calc
  logic       exp_calc_sign;
  logic       exp_calc_is_inf;
  logic       exp_calc_is_zero;
  logic       exp_calc_is_nan;
  logic       flag_overflow;
  logic       flag_underflow;
  logic       flag_pot_underflow;
  logic       flag_invalid;
  logic [9:0] exp_calc_result;

  always_ff @(posedge clk_i) begin
    if (exp_valid_pipe[3]) begin
      exp_calc_sign <= pipe_sign_a[3] ^ pipe_sign_b[3];

      exp_calc_is_inf <= 0;
      exp_calc_is_zero <= 0;
      exp_calc_is_nan <= 0;
      flag_overflow <= 0;
      flag_underflow <= 0;
      flag_pot_underflow <= 0;
      flag_invalid <= 0;
      exp_calc_result <= 0;

      if (pipe_inv_op[3] || pipe_in_nan[3]) begin
        exp_calc_is_nan <= 1;
        // Raise Invalid if Op is Invalid OR if Input was Signaling NaN
        flag_invalid    <= pipe_inv_op[3] || pipe_in_snan[3];
      end else if (pipe_in_inf[3]) begin
        exp_calc_is_inf <= 1;
      end else if (pipe_in_zero[3]) begin
        exp_calc_is_zero <= 1;
      end else if (pipe_sum[3] >= 10'd382) begin
        exp_calc_is_inf <= 1;
        flag_overflow   <= 1;
        exp_calc_result <= 10'd255;
      end else if (pipe_sum[3] < 10'd127) begin
        exp_calc_is_zero <= 1;
        flag_underflow   <= 1;
        exp_calc_result  <= 0;
      end else if (pipe_sum[3] == 10'd127) begin
        flag_pot_underflow <= 1;
        exp_calc_result    <= 0;
      end else begin
        exp_calc_result <= pipe_sum[3] - 10'd127;
      end
    end
  end

  typedef struct packed {
    logic       is_nan;
    logic       is_inf;
    logic       is_zero;
    logic       flag_ov;
    logic       flag_un;
    logic       flag_pot_un;
    logic       flag_inv;
    logic       sign;
    logic [9:0] exp;
  } meta_data_t;

  meta_data_t sync_data;

  logic [$bits(meta_data_t)-1:0] delay_reg;
  always_ff @(posedge clk_i) begin
    delay_reg <= {
      exp_calc_is_nan,
      exp_calc_is_inf,
      exp_calc_is_zero,
      flag_overflow,
      flag_underflow,
      flag_pot_underflow,
      flag_invalid,
      exp_calc_sign,
      exp_calc_result
    };
  end
  assign sync_data = delay_reg;

  logic final_is_underflow;
  logic [7:0] final_exp;
  logic [22:0] final_man;

  always_comb begin
    final_is_underflow = sync_data.flag_un || (sync_data.flag_pot_un && !raw_product[47]);

    if (raw_product[47]) begin
      final_man = raw_product[46:24];
      final_exp = sync_data.exp[7:0] + 1'b1;
    end else begin
      final_man = raw_product[45:23];
      final_exp = sync_data.exp[7:0];
    end
  end

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
        overflow_o  <= sync_data.flag_ov;
        invalid_o   <= sync_data.flag_inv;
        underflow_o <= final_is_underflow;

        if (sync_data.is_nan) result_o <= 32'h7FC00000;
        else if (sync_data.is_inf) result_o <= {sync_data.sign, 8'hFF, 23'd0};
        else if (sync_data.is_zero || final_is_underflow) begin
          result_o <= {sync_data.sign, 31'd0};
        end else begin
          if (final_exp == 8'hFF) begin
            result_o   <= {sync_data.sign, 8'hFF, 23'd0};
            overflow_o <= 1'b1;
          end else begin
            result_o <= {sync_data.sign, final_exp, final_man};
          end
        end
      end else begin
        overflow_o  <= 0;
        underflow_o <= 0;
        invalid_o   <= 0;
      end
    end
  end

endmodule
