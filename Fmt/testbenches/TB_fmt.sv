`timescale 1ns / 100ps

// A Fmt wrapper (fmt_mul, fmt_add) against the unit it selects, or a package function (fmt_greater_than, fmt_relu) against the inline logic it
// replaces, under the build's define: every cycle the same done_o, every done the same word, done exactly the package's latency after
// valid_i. KIND is mul, add, cmp or relu; +N=<vectors>, +SEED=<seed>; RESULT: PASSED or FAILED.
module TB_fmt;
  import sienna_fmt_pkg::*;
  parameter string KIND = "mul";
`ifdef FMT_INT8
  localparam bit FLOATS = 1'b0;
  parameter int MUL_DATA_WIDTH = DATA_WIDTH;
  parameter int MUL_EXT_DATA_WIDTH = 2 * MUL_DATA_WIDTH;  // fmt_mul's EXT_DATA_WIDTH (the PE's is ACC_DATA_WIDTH)
`else
  localparam bit FLOATS = 1'b1;
  parameter int MUL_DATA_WIDTH = DATA_WIDTH;
  parameter int MUL_EXT_DATA_WIDTH = MUL_DATA_WIDTH;  // bf16's PE product is 32
`endif
  parameter int ADD_DATA_WIDTH = ACC_DATA_WIDTH;  // fmt_add's DATA_WIDTH: ACC_DATA_WIDTH (accumulator add), or bf16's lane width

  // Each kind: its latency in the package, and whether it is combinational (no clock, no valid).
  localparam int EXPECTED_LATENCY = (KIND == "mul") ? mul_latency(MUL_DATA_WIDTH, MUL_EXT_DATA_WIDTH) : (KIND == "add") ? add_latency(ADD_DATA_WIDTH) : 0;
  localparam bit IS_COMBINATIONAL = (KIND == "cmp") || (KIND == "relu");

  logic clk = 1'b0, rstn = 1'b0;
  always #5 clk = ~clk;

  logic        valid;
  logic [63:0] a, b, c;  // operands, sliced per kind
  logic [63:0] wrapper_result, unit_result;
  logic        dut_done, ref_done;

  // ── a random operand: floats biased to the special exponents and mantissas, integers to the ends of the range ──
  function automatic logic [63:0] rnd_float(input int bits);
    automatic int man = bits - 9;
    automatic logic [63:0] m, e;
    automatic int k = $urandom_range(0, 15);
    case (k)
      0: e = 0; 1: e = 1; 2: e = 2; 3: e = 126; 4: e = 127; 5: e = 128; 6: e = 253; 7: e = 254; 8: e = 255;
      default: e = 64'($urandom_range(0, 255));
    endcase
    k = $urandom_range(0, 7);
    m = (k == 0) ? 64'd0 : (k == 1) ? 64'd1 : (k == 2) ? ((64'd1 << man) - 1) : (k == 3) ? (64'd1 << (man - 1)) :
        ({$urandom, $urandom} & ((64'd1 << man) - 1));
    return (64'($urandom_range(0, 1)) << (bits - 1)) | (e << man) | m;
  endfunction
  function automatic logic [63:0] rnd_int(input int bits);
    automatic int k = $urandom_range(0, 9);
    automatic logic [63:0] mask = (bits == 64) ? '1 : ((64'd1 << bits) - 1);
    automatic logic [63:0] v = (k == 0) ? 64'd0 : (k == 1) ? 64'd1 : (k == 2) ? mask : (k == 3) ? (64'd1 << (bits - 1)) :
                               (k == 4) ? ((64'd1 << (bits - 1)) - 1) : {$urandom, $urandom};
    return v & mask;
  endfunction
  function automatic logic [63:0] rnd_word(input int bits, input bit fl);
    return fl ? rnd_float(bits) : rnd_int(bits);
  endfunction

  // ── the wrapper and the unit it selects, or the function and the inline logic it replaces, per kind ──
  if (KIND == "mul") begin : G_MUL
    logic [MUL_EXT_DATA_WIDTH-1:0] wrapper_word, unit_word;
    fmt_mul #(.DATA_WIDTH(MUL_DATA_WIDTH), .EXT_DATA_WIDTH(MUL_EXT_DATA_WIDTH)) DUT (.clk_i(clk), .rstn_i(rstn), .valid_i(valid),
        .a_i(a[MUL_DATA_WIDTH-1:0]), .b_i(b[MUL_DATA_WIDTH-1:0]), .product_o(wrapper_word), .done_o(dut_done));
`ifdef FMT_INT8
    logic signed [15:0] int8_product;
    int8Multiplier REF (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .a_i(a[7:0]), .b_i(b[7:0]), .result_o(int8_product), .done_o(ref_done));
    assign unit_word = MUL_EXT_DATA_WIDTH'(int8_product);  // sign-extended: PE-4's extension, now inside fmt_mul
`elsif FMT_BF16
    if (MUL_EXT_DATA_WIDTH == 32) begin : G_WIDEN
      bf16WideMultiplier REF (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .a_i(a[15:0]), .b_i(b[15:0]), .result_o(unit_word), .done_o(ref_done),
          .overflow_o(), .underflow_o(), .invalid_o());
    end else begin : G_LANE
      bf16Multiplier REF (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .a_i(a[15:0]), .b_i(b[15:0]), .result_o(unit_word), .done_o(ref_done),
          .overflow_o(), .underflow_o(), .invalid_o());
    end
`else
    fp32Multiplier REF (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a[31:0]), .B(b[31:0]), .result_o(unit_word), .done_o(ref_done),
        .overflow_o(), .underflow_o(), .invalid_o());
`endif
    assign wrapper_result = 64'(wrapper_word);
    assign unit_result = 64'(unit_word);
  end else if (KIND == "add") begin : G_ADD
    logic [ADD_DATA_WIDTH-1:0] wrapper_word, unit_word;
    fmt_add #(.DATA_WIDTH(ADD_DATA_WIDTH)) DUT (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .a_i(a[ADD_DATA_WIDTH-1:0]),
        .b_i(b[ADD_DATA_WIDTH-1:0]), .sum_o(wrapper_word), .done_o(dut_done));
`ifdef FMT_INT8
    int32Adder REF (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .a_i(a[31:0]), .b_i(b[31:0]), .result_o(unit_word), .done_o(ref_done));
`else
    if (ADD_DATA_WIDTH == 32) begin : G_FP32
      fp32Adder REF (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a[31:0]), .B(b[31:0]), .result_o(unit_word), .done_o(ref_done), .overflow_o(),
          .underflow_o(), .invalid_o());
    end else begin : G_BF16
      bf16Adder REF (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .a_i(a[15:0]), .b_i(b[15:0]), .result_o(unit_word), .done_o(ref_done), .overflow_o(),
          .underflow_o(), .invalid_o());
    end
`endif
    assign wrapper_result = 64'(wrapper_word);
    assign unit_result = 64'(unit_word);
  end else if (KIND == "cmp") begin : G_CMP
    logic wrapper_greater;
    fmt_fn_cmp DUT (.a_i(a[DATA_WIDTH-1:0]), .b_i(b[DATA_WIDTH-1:0]), .greater_o(wrapper_greater));
    // Maxpool_2D's is_greater, copied: the compare fmt_greater_than replaces
    function automatic logic is_greater(input logic [DATA_WIDTH-1:0] x, input logic [DATA_WIDTH-1:0] y);
      if (FLOATS) begin
        if ((x[DATA_WIDTH-2:0] == 0) && (y[DATA_WIDTH-2:0] == 0)) return 1'b0;
        if (x[DATA_WIDTH-1] != y[DATA_WIDTH-1]) return !x[DATA_WIDTH-1];
        if (!x[DATA_WIDTH-1]) return x[DATA_WIDTH-2:0] > y[DATA_WIDTH-2:0];
        return x[DATA_WIDTH-2:0] < y[DATA_WIDTH-2:0];
      end
      return $signed(x) > $signed(y);
    endfunction
    assign wrapper_result = 64'(wrapper_greater);
    assign unit_result = 64'(is_greater(a[DATA_WIDTH-1:0], b[DATA_WIDTH-1:0]));
  end else if (KIND == "relu") begin : G_RELU
    logic [DATA_WIDTH-1:0] wrapper_word;
    fmt_fn_relu DUT (.x_i(a[DATA_WIDTH-1:0]), .zero_point_i(b[DATA_WIDTH-1:0]), .y_o(wrapper_word));
    assign wrapper_result = 64'(wrapper_word);
    // gpnae_poly's bypass write (is_relu && sign ? 0 : x); gpnae_poly_int8's (q < z_in ? z_in : q)
    assign unit_result = FLOATS ? ((a[DATA_WIDTH-1]) ? 64'd0 : 64'(a[DATA_WIDTH-1:0]))
                          : (($signed(a[DATA_WIDTH-1:0]) < $signed(b[DATA_WIDTH-1:0])) ? 64'(b[DATA_WIDTH-1:0]) : 64'(a[DATA_WIDTH-1:0]));
  end else begin : G_BAD_KIND
    $fatal(1, "TB_fmt: unknown KIND %s", KIND);
  end

  if (IS_COMBINATIONAL) begin : G_COMB_DONE
    assign dut_done = 1'b0;
    assign ref_done = 1'b0;
  end

  // ── stimulus and checks: inputs change at the negedge, outputs are read 1 ns later ──
  int n_vec = 100000, seed = 1;
  int issued = 0, done_n = 0, mism = 0, done_mism = 0, lat_err = 0, cycle = 0;
  int issue_q[$];

  task automatic new_operands();
    automatic int operand_bits = (KIND == "add") ? ADD_DATA_WIDTH : (KIND == "mul") ? MUL_DATA_WIDTH : DATA_WIDTH;
    // floats in float builds (the accumulator path is fp32 there), integers in int8
    a = rnd_word(operand_bits, FLOATS);
    b = rnd_word(operand_bits, FLOATS);
    c = rnd_word(operand_bits, FLOATS);
    if (KIND == "relu" && !FLOATS) b = rnd_int(8);  // the zero point
  endtask

  initial begin
    void'($value$plusargs("N=%d", n_vec));
    void'($value$plusargs("SEED=%d", seed));
    void'($urandom(seed));
    valid = 1'b0;
    a = '0;
    b = '0;
    c = '0;
    repeat (3) @(negedge clk);
    rstn = 1'b1;
    while (issued < n_vec || (!IS_COMBINATIONAL && issue_q.size() != 0)) begin
      @(negedge clk);
      cycle++;
      // a vector this cycle with probability 3/4 (always in bursts of the first 64)
      valid = (issued < n_vec) && ((issued < 64) || ($urandom_range(0, 3) != 0));
      if (valid) new_operands();
      #1;
      if (IS_COMBINATIONAL) begin
        if (valid) begin
          issued++;
          done_n++;
          if (wrapper_result !== unit_result) begin
            mism++;
            if (mism <= 10) $display("MISMATCH %s %s: a %h b %h: wrapper %h, unit %h", KIND, FORMAT_NAME, a, b, wrapper_result, unit_result);
          end
        end
      end else begin
        if (valid) begin
          issue_q.push_back(cycle);
          issued++;
        end
        if (dut_done !== ref_done) begin
          done_mism++;
          if (done_mism <= 10) $display("DONE MISMATCH %s %s at cycle %0d: wrapper %b, unit %b", KIND, FORMAT_NAME, cycle, dut_done, ref_done);
        end
        if (dut_done === 1'b1) begin
          automatic int t0 = (issue_q.size() != 0) ? issue_q.pop_front() : -1;
          done_n++;
          if (cycle - t0 != EXPECTED_LATENCY) begin
            lat_err++;
            if (lat_err <= 10) $display("LATENCY %s %s: issued at %0d, done at %0d, package latency %0d", KIND, FORMAT_NAME, t0, cycle, EXPECTED_LATENCY);
          end
          if (wrapper_result !== unit_result) begin
            mism++;
            if (mism <= 10) $display("MISMATCH %s %s at cycle %0d: wrapper %h, unit %h", KIND, FORMAT_NAME, cycle, wrapper_result, unit_result);
          end
        end
        if (cycle > 4 * n_vec + 1000) begin
          $display("TIMEOUT %s %s: %0d issued, %0d done", KIND, FORMAT_NAME, issued, done_n);
          break;
        end
      end
    end
    $display("TB_fmt %s%s %s: %0d vectors, %0d done, %0d result mismatches, %0d done mismatches, %0d latency errors (latency %0d)",
             KIND, (KIND == "add") ? $sformatf(" DATA_WIDTH=%0d", ADD_DATA_WIDTH)
                 : (KIND == "mul") ? $sformatf(" DATA_WIDTH=%0d EXT_DATA_WIDTH=%0d", MUL_DATA_WIDTH, MUL_EXT_DATA_WIDTH) : "", FORMAT_NAME, issued,
             done_n, mism, done_mism, lat_err, IS_COMBINATIONAL ? 0 : EXPECTED_LATENCY);
    if (issued == n_vec && done_n == n_vec && mism == 0 && done_mism == 0 && lat_err == 0) $display("RESULT: PASSED");
    else $display("RESULT: FAILED");
    $finish;
  end
endmodule
