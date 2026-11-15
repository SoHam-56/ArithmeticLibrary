`timescale 1ns / 100ps

module fp32Adder (
    input wire        clk_i,
    input wire        rstn_i,
    input wire        valid_i,
    input wire [31:0] A,
    input wire [31:0] B,

    output reg [31:0] result_o,
    output reg        done_o,
    output reg        overflow_o,
    output reg        underflow_o,
    output reg        invalid_o
);

  typedef struct packed {
    logic       is_invalid_op;  // Set for (Inf - Inf) OR Signaling NaN inputs
    logic       is_nan;         // Result is NaN
    logic       is_inf;         // Result is Inf
    logic       is_zero;
    logic       pure_bypass;
    logic       sign;
    logic [7:0] exp;
    logic       op_sub;
  } meta_t;

  // Stage 0: the unpacked operands, their classes, the magnitude compare and both exponent differences, registered (the compare and the
  // difference into the big/small select was one of the adder's two 1.3 ns stages at 45 nm).
  logic        s0_valid;
  logic        s0_sa, s0_sb;
  logic [7:0]  s0_ea, s0_eb;
  logic [22:0] s0_ma, s0_mb;
  logic        s0_hidden_a, s0_hidden_b;
  logic        s0_a_nan, s0_b_nan, s0_a_inf, s0_b_inf, s0_a_zero, s0_b_zero, s0_a_snan, s0_b_snan;
  logic        s0_op_sub, s0_comp_a_ge_b;
  logic [7:0]  s0_dab, s0_dba;  // ea - eb, eb - ea
  // Stage 1: the operands ordered by magnitude, their exponent difference, the class.
  logic sa, sb;
  logic [7:0] ea, eb;
  logic [22:0] ma_raw, mb_raw;
  logic [22:0] ma, mb;
  logic hidden_a, hidden_b;
  logic a_nan, b_nan, a_inf, b_inf, a_zero, b_zero;
  logic a_snan, b_snan;  // New signals for SNaN detection
  logic op_sub_wire;
  logic comp_a_ge_b;
  logic       s1_valid;
  logic [7:0] s1_diff;
  logic [23:0] s1_man_big, s1_man_small;
  meta_t s1_meta;
  // Stage 2: the aligned significands.
  logic         s2_valid;
  logic  [26:0] s2_man_big;
  logic  [26:0] s2_man_small;
  meta_t        s2_meta;
  // Stage 3: the sum.
  logic         s3_valid;
  logic  [27:0] s3_sum;
  meta_t        s3_meta;
  // Stage 4: the sum and its leading zeros.
  logic         s4_valid;
  logic  [27:0] s4_sum;
  logic  [ 4:0] s4_lzc;
  meta_t        s4_meta;
  logic  [ 4:0] lzc_module_out;
  // Stage 5: the normalized mantissa and exponent, registered (the leading-zero shift and the exponent subtract into the result mux was the
  // adder's other 1.3 ns stage); stage 6 packs the result.
  logic [27:0] norm_man;
  logic [ 8:0] norm_exp;
  logic [ 4:0] shift_amt;
  logic        s5_valid;
  /* verilator lint_off UNUSEDSIGNAL */  // the carry, hidden-bit and guard bits of s5_man are dropped by truncation; s5_meta's exp and op_sub are spent
  logic [27:0] s5_man;
  meta_t       s5_meta;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [ 8:0] s5_exp;

  // =========================================================================
  // STAGE 1: Unpack, Detect Specials, Align
  // =========================================================================
  always_comb begin
    // Unpack Raw
    {sa, ea, ma_raw} = A;
    {sb, eb, mb_raw} = B;

    // FORCE FLUSH TO ZERO (FTZ)
    if (ea == 0) ma = 23'd0;
    else ma = ma_raw;
    if (eb == 0) mb = 23'd0;
    else mb = mb_raw;

    // Hidden Bits
    hidden_a = (ea != 0);
    hidden_b = (eb != 0);

    // Classification (Using Flushed Values)
    a_zero = (ea == 0);
    b_zero = (eb == 0);

    // NaN Detection
    a_nan = (ea == 255) && (ma_raw != 0);
    b_nan = (eb == 255) && (mb_raw != 0);

    // SNaN Detection (Signaling NaN)
    // In IEEE 754-2008, MSB of Mantissa (bit 22) is 0 for SNaN, 1 for QNaN.
    a_snan = a_nan && (ma_raw[22] == 0);
    b_snan = b_nan && (mb_raw[22] == 0);

    // Inf Detection
    a_inf = (ea == 255) && (ma_raw == 0);
    b_inf = (eb == 255) && (mb_raw == 0);

    op_sub_wire = sa ^ sb;

    // Compare Magnitude
    if ({ea, ma} >= {eb, mb}) comp_a_ge_b = 1'b1;
    else comp_a_ge_b = 1'b0;
  end

  // Stage 0: the unpacked operands, their classes, the compare and both differences.
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) s0_valid <= 1'b0;
    else s0_valid <= valid_i;
  always_ff @(posedge clk_i)
    if (valid_i) begin
      {s0_sa, s0_sb, s0_ea, s0_eb, s0_ma, s0_mb} <= {sa, sb, ea, eb, ma, mb};
      {s0_hidden_a, s0_hidden_b} <= {hidden_a, hidden_b};
      {s0_a_nan, s0_b_nan, s0_a_inf, s0_b_inf, s0_a_zero, s0_b_zero, s0_a_snan, s0_b_snan} <= {a_nan, b_nan, a_inf, b_inf, a_zero, b_zero, a_snan, b_snan};
      s0_op_sub      <= op_sub_wire;
      s0_comp_a_ge_b <= comp_a_ge_b;
      s0_dab         <= ea - eb;
      s0_dba         <= eb - ea;
    end

  // Stage 1: the operands ordered by magnitude, their exponent difference, the class.
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s1_valid     <= 0;
      s1_diff      <= 0;
      s1_man_big   <= 0;
      s1_man_small <= 0;
      s1_meta      <= '0;
    end else begin
      s1_valid <= s0_valid;
      if (s0_valid) begin
        // 1. Invalid Operation:
        //    Case A: Inf - Inf
        //    Case B: Any Signaling NaN Input
        s1_meta.is_invalid_op <= ((s0_a_inf && s0_b_inf) && (s0_sa != s0_sb)) || (s0_a_snan || s0_b_snan);

        // 2. Result NaN: Any Input NaN OR Invalid Op
        s1_meta.is_nan        <= (s0_a_nan || s0_b_nan) || ((s0_a_inf && s0_b_inf) && (s0_sa != s0_sb));

        // 3. Result Inf: Any Input Inf (Unless it's the invalid case)
        s1_meta.is_inf        <= (s0_a_inf || s0_b_inf);

        s1_meta.is_zero       <= (s0_a_zero && s0_b_zero);
        s1_meta.pure_bypass   <= (s0_a_zero ^ s0_b_zero);
        s1_meta.op_sub        <= s0_op_sub;

        if (s0_comp_a_ge_b) begin
          s1_man_big   <= {s0_hidden_a, s0_ma};
          s1_man_small <= {s0_hidden_b, s0_mb};
          s1_diff      <= s0_dab;
          s1_meta.exp  <= s0_ea;
          s1_meta.sign <= s0_sa;
        end else begin
          s1_man_big   <= {s0_hidden_b, s0_mb};
          s1_man_small <= {s0_hidden_a, s0_ma};
          s1_diff      <= s0_dba;
          s1_meta.exp  <= s0_eb;
          s1_meta.sign <= s0_sb;
        end
      end
    end
  end

  // =========================================================================
  // STAGE 2: Align Shift
  // =========================================================================
  always_ff @(posedge clk_i) begin
    s2_valid <= s1_valid;
    if (s1_valid) begin
      s2_meta    <= s1_meta;
      s2_man_big <= {s1_man_big, 3'b0};

      if (s1_meta.pure_bypass) begin
        s2_man_small <= 0;
      end else begin
        if (s1_diff >= 26) s2_man_small <= 27'b1;
        else s2_man_small <= {s1_man_small, 3'b0} >> s1_diff;
      end
    end
  end

  // =========================================================================
  // STAGE 3: Add/Sub
  // =========================================================================
  always_ff @(posedge clk_i) begin
    s3_valid <= s2_valid;
    if (s2_valid) begin
      s3_meta <= s2_meta;
      if (s2_meta.op_sub) s3_sum <= {1'b0, s2_man_big} - {1'b0, s2_man_small};
      else s3_sum <= {1'b0, s2_man_big} + {1'b0, s2_man_small};
    end
  end

  // =========================================================================
  // STAGE 4: Normalize & Output
  // =========================================================================
  cntlz28 u_lzc (
      .i(s3_sum),
      .o(lzc_module_out)
  );

  always_ff @(posedge clk_i) begin
    s4_valid <= s3_valid;
    if (s3_valid) begin
      s4_sum  <= s3_sum;
      s4_meta <= s3_meta;
      s4_lzc  <= lzc_module_out;
      if (s3_sum == 0) s4_meta.is_zero <= 1'b1;
    end
  end

  always_comb begin
    norm_man  = s4_sum;
    norm_exp  = {1'b0, s4_meta.exp};
    shift_amt = 0;

    if (s4_meta.pure_bypass) begin
      norm_man = s4_sum;
      norm_exp = s4_meta.exp;
    end else begin
      if (s4_sum[27]) begin
        norm_man = s4_sum >> 1;
        norm_exp = s4_meta.exp + 1;
      end else if (s4_lzc == 1) begin
        norm_man = s4_sum;
        norm_exp = s4_meta.exp;
      end else if (s4_meta.is_zero) begin
        norm_man = 0;
        norm_exp = 0;
      end else if (s4_lzc > 1) begin
        shift_amt = s4_lzc - 1;
        norm_man  = s4_sum << shift_amt;
        norm_exp  = s4_meta.exp - shift_amt;
      end
    end
  end

  // Stage 5: the normalized mantissa and exponent, registered.
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) s5_valid <= 1'b0;
    else s5_valid <= s4_valid;
  always_ff @(posedge clk_i)
    if (s4_valid) begin
      s5_man  <= norm_man;
      s5_exp  <= norm_exp;
      s5_meta <= s4_meta;
    end

  // Stage 6: the result and its flags.
  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      result_o    <= 0;
      done_o      <= 0;
      overflow_o  <= 0;
      underflow_o <= 0;
      invalid_o   <= 0;
    end else begin
      done_o <= s5_valid;

      if (s5_valid) begin
        // --- Flag Logic ---
        invalid_o <= s5_meta.is_invalid_op;

        if ((s5_exp >= 255) && !s5_meta.is_inf && !s5_meta.is_nan) begin
          overflow_o <= 1'b1;
        end else begin
          overflow_o <= 0;
        end

        underflow_o <= 0;

        // --- Result Mux ---
        if (s5_meta.is_nan) begin
          result_o <= 32'h7FC00000;  // Force Quiet NaN
        end else if (s5_meta.is_inf) begin
          result_o <= {s5_meta.sign, 8'hFF, 23'h0};
        end else if (s5_meta.is_zero) begin
          result_o <= {s5_meta.sign, 31'h0};
        end else if ($signed(s5_exp) <= 0 && !s5_meta.pure_bypass) begin
          result_o    <= {s5_meta.sign, 31'h0};
          underflow_o <= 1'b1;
        end else if (s5_exp >= 255) begin
          result_o <= {s5_meta.sign, 8'hFF, 23'h0};
        end else begin
          result_o <= {s5_meta.sign, s5_exp[7:0], s5_man[25:3]};
        end
      end else begin
        overflow_o  <= 0;
        underflow_o <= 0;
        invalid_o   <= 0;
      end
    end
  end

endmodule
