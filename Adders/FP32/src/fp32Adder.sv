`timescale 1ns / 100ps

module fp32Adder (
    input logic        clk_i,
    input logic        rstn_i,
    input logic        valid_i,
    input logic [31:0] A,
    input logic [31:0] B,

    output logic [31:0] result_o,
    output logic        done_o,
    output logic        overflow_o,
    output logic        underflow_o,
    output logic        invalid_o
);

  typedef struct packed {
    logic is_nan;
    logic is_inf;
    logic is_zero;
    logic pure_bypass;
    logic sign;
    logic [7:0] exp;
    logic op_sub;
  } meta_t;

  logic       s1_valid;
  logic [7:0] s1_diff;
  logic [23:0] s1_man_big, s1_man_small;
  meta_t s1_meta;


  logic sa, sb;
  logic [7:0] ea, eb;
  logic [22:0] ma_raw, mb_raw;  // Original Mantissas
  logic [22:0] ma, mb;          // Flushed Mantissas
  logic hidden_a, hidden_b;
  logic a_nan, b_nan, a_inf, b_inf, a_zero, b_zero;
  logic op_sub_wire;
  logic comp_a_ge_b;

  always_comb begin
    // Unpack Raw
    {sa, ea, ma_raw} = A;
    {sb, eb, mb_raw} = B;

    // FORCE FLUSH TO ZERO
    // If exponent is 0, we kill the mantissa. This forces subnormals to 0.
    if (ea == 0) ma = 23'd0;
    else ma = ma_raw;
    if (eb == 0) mb = 23'd0;
    else mb = mb_raw;

    // Hidden Bits
    // Since subnormals are flushed, ea!=0 guarantees a normal number (hidden=1)
    hidden_a = (ea != 0);
    hidden_b = (eb != 0);

    // Classification (Using Flushed Values)
    a_zero = (ea == 0);                   // Mantissa is already forced to 0 above
    b_zero = (eb == 0);

    a_nan = (ea == 255) && (ma_raw != 0);  // NaNs preserve payload
    b_nan = (eb == 255) && (mb_raw != 0);
    a_inf = (ea == 255) && (ma_raw == 0);
    b_inf = (eb == 255) && (mb_raw == 0);

  
    op_sub_wire = sa ^ sb;

    // Compare Magnitude
    if ({ea, ma} >= {eb, mb}) comp_a_ge_b = 1'b1;
    else comp_a_ge_b = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rstn_i) begin
    if (!rstn_i) begin
      s1_valid     <= 0;
      s1_diff      <= 0;
      s1_man_big   <= 0;
      s1_man_small <= 0;
      s1_meta      <= '0;
    end else begin
      s1_valid <= valid_i;
      if (valid_i) begin
        s1_meta.is_nan      <= (a_nan || b_nan) || ((a_inf && b_inf) && (sa != sb));
        s1_meta.is_inf      <= (a_inf || b_inf);
        s1_meta.is_zero     <= (a_zero && b_zero);
        s1_meta.pure_bypass <= (a_zero ^ b_zero);
        s1_meta.op_sub      <= op_sub_wire;

        if (comp_a_ge_b) begin
          s1_man_big   <= {hidden_a, ma};
          s1_man_small <= {hidden_b, mb};
          s1_diff      <= ea - eb;
          s1_meta.exp  <= ea;
          s1_meta.sign <= sa;
        end else begin
          s1_man_big   <= {hidden_b, mb};
          s1_man_small <= {hidden_a, ma};
          s1_diff      <= eb - ea;
          s1_meta.exp  <= eb;
          s1_meta.sign <= sb;
        end
      end
    end
  end

  logic         s2_valid;
  logic  [26:0] s2_man_big;
  logic  [26:0] s2_man_small;
  meta_t        s2_meta;

  always_ff @(posedge clk_i) begin
    s2_valid <= s1_valid;
    if (s1_valid) begin
      s2_meta    <= s1_meta;
      s2_man_big <= {s1_man_big, 3'b0};

      if (s1_meta.pure_bypass) begin
        s2_man_small <= 0;                      // Optimization: Force 0 for quiet adder
      end else begin
        if (s1_diff >= 26) s2_man_small <= 27'b1;
        else s2_man_small <= {s1_man_small, 3'b0} >> s1_diff;
      end
    end
  end

  logic         s3_valid;
  logic  [27:0] s3_sum;
  meta_t        s3_meta;

  always_ff @(posedge clk_i) begin
    s3_valid <= s2_valid;
    if (s2_valid) begin
      s3_meta <= s2_meta;
      if (s2_meta.op_sub) s3_sum <= {1'b0, s2_man_big} - {1'b0, s2_man_small};
      else s3_sum <= {1'b0, s2_man_big} + {1'b0, s2_man_small};
    end
  end

  logic         s4_valid;
  logic  [27:0] s4_sum;
  logic  [ 4:0] s4_lzc;
  meta_t        s4_meta;

  logic  [ 4:0] lzc_module_out;

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

  logic [27:0] norm_man;
  logic [ 8:0] norm_exp;
  logic [ 4:0] shift_amt;

  always_comb begin

    norm_man  = s4_sum;
    norm_exp  = {1'b0, s4_meta.exp};
    shift_amt = 0;

    if (s4_meta.pure_bypass) begin
      norm_man = s4_sum;
      norm_exp = s4_meta.exp;
    end else begin
      if (s4_sum[27]) begin
        // Carry: Shift Right 1
        norm_man = s4_sum >> 1;
        norm_exp = s4_meta.exp + 1;
      end else if (s4_lzc == 1) begin
        // Normal: No shift
        norm_man = s4_sum;
        norm_exp = s4_meta.exp;
      end else if (s4_meta.is_zero) begin
        norm_man = 0;
        norm_exp = 0;
      end else if (s4_lzc > 1) begin
        // Cancellation: Shift Left
        shift_amt = s4_lzc - 1;
        norm_man  = s4_sum << shift_amt;
        norm_exp  = s4_meta.exp - shift_amt;
      end
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
      done_o <= s4_valid;

      if (s4_valid) begin
        overflow_o  <= 0;
        underflow_o <= 0;
        invalid_o   <= s4_meta.is_nan;

        if (s4_meta.is_nan) begin
          result_o <= 32'h7FC00000;
        end else if (s4_meta.is_inf) begin
          result_o   <= {s4_meta.sign, 8'hFF, 23'h0};
          overflow_o <= 1'b1;
        end else if (s4_meta.is_zero) begin
          result_o <= {s4_meta.sign, 31'h0};
        end else if ($signed(norm_exp) <= 0 && !s4_meta.pure_bypass) begin
          // Flush Result Underflow to Zero
          result_o    <= {s4_meta.sign, 31'h0};
          underflow_o <= 1'b1;
        end else if (norm_exp >= 255) begin
          result_o   <= {s4_meta.sign, 8'hFF, 23'h0};
          overflow_o <= 1'b1;
        end else begin
          result_o <= {s4_meta.sign, norm_exp[7:0], norm_man[25:3]};
        end
      end else begin
        overflow_o  <= 0;
        underflow_o <= 0;
        invalid_o   <= 0;
      end
    end
  end

endmodule
