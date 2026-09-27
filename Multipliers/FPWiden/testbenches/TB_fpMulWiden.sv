`timescale 1ns / 100ps

// Checks fpMulWiden against fp32Multiplier on the same values widened to fp32: result and flags must match bit for bit.
// Stimulus: every special class against every other, exponents at the fp32 underflow and overflow edges, and random pairs.
module TB_fpMulWiden #(
    parameter int EXP_W   = 8,
    parameter int MAN_W   = 7,
    parameter int RANDOM  = 200000
);
  localparam int W = 1 + EXP_W + MAN_W;
  localparam int BIAS = (1 << (EXP_W - 1)) - 1;
  localparam logic [EXP_W-1:0] ONES = '1;

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;

  logic valid = 0;
  logic [W-1:0] a, b;
  logic [31:0] res_d, res_r;
  logic done_d, done_r, ov_d, ov_r, un_d, un_r, inv_d, inv_r;

  // The value exactly, in fp32: subnormals read as zero, as both units treat them.
  function automatic logic [31:0] to32(input logic [W-1:0] x);
    automatic logic [EXP_W-1:0] e = x[W-2:MAN_W];
    automatic logic [22:0] m = 23'(x[MAN_W-1:0]) << (23 - MAN_W);
    if (e == '0) return {x[W-1], 31'd0};
    if (e == ONES) return {x[W-1], 8'hFF, m};
    return {x[W-1], 8'(int'(e) - BIAS + 127), m};
  endfunction

  fpMulWiden #(.EXP_W(EXP_W), .MAN_W(MAN_W)) dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .B(b),
      .result_o(res_d), .done_o(done_d), .overflow_o(ov_d), .underflow_o(un_d), .invalid_o(inv_d));
  fp32Multiplier ref_mul (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(to32(a)), .B(to32(b)),
      .result_o(res_r), .done_o(done_r), .overflow_o(ov_r), .underflow_o(un_r), .invalid_o(inv_r));

  logic [34:0] q_d[$], q_r[$];  // {result, overflow, underflow, invalid} in issue order
  logic [W-1:0] q_a[$], q_b[$];
  always_ff @(posedge clk) begin
    if (done_d) q_d.push_back({res_d, ov_d, un_d, inv_d});
    if (done_r) q_r.push_back({res_r, ov_r, un_r, inv_r});
  end

  function automatic logic [W-1:0] mk(input bit s, input int e, input int m);
    return {s, EXP_W'(e), MAN_W'(m)};
  endfunction

  logic [W-1:0] va[$], vb[$];
  int errs = 0, checked = 0;

  initial begin
    automatic logic [W-1:0] special[$];
    automatic int max_e = (1 << EXP_W) - 2;
    // Zero, a subnormal pattern, smallest and largest normals, one, infinity, quiet and signaling NaN, both signs.
    for (int s = 0; s < 2; s++) begin
      special.push_back(mk(s, 0, 0));
      special.push_back(mk(s, 0, 1));
      special.push_back(mk(s, 1, 0));
      special.push_back(mk(s, max_e, (1 << MAN_W) - 1));
      special.push_back(mk(s, BIAS, 0));
      special.push_back(mk(s, BIAS, (1 << MAN_W) - 1));
      special.push_back(mk(s, max_e + 1, 0));
      special.push_back(mk(s, max_e + 1, 1 << (MAN_W - 1)));
      special.push_back(mk(s, max_e + 1, 1));
    end
    foreach (special[i]) foreach (special[j]) begin
      va.push_back(special[i]);
      vb.push_back(special[j]);
    end
    // Exponent pairs whose fp32 product sits at the underflow and overflow edges, with random mantissas.
    for (int ea = 1; ea <= max_e; ea++) begin
      for (int k = 0; k < 8; k++) begin
        automatic int eb_lo = 127 + 2 * BIAS - 127 - ea + (k - 4);  // biased product exponent near 0
        automatic int eb_hi = 254 + 2 * BIAS - 127 - ea + (k - 4);  // near 255
        if (eb_lo >= 1 && eb_lo <= max_e) begin
          va.push_back(mk($urandom_range(0, 1), ea, $urandom));
          vb.push_back(mk($urandom_range(0, 1), eb_lo, $urandom));
        end
        if (eb_hi >= 1 && eb_hi <= max_e) begin
          va.push_back(mk($urandom_range(0, 1), ea, $urandom));
          vb.push_back(mk($urandom_range(0, 1), eb_hi, $urandom));
        end
      end
    end
    for (int i = 0; i < RANDOM; i++) begin
      va.push_back(W'($urandom));
      vb.push_back(W'($urandom));
    end

    repeat (3) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    foreach (va[i]) begin
      #1;
      valid = 1;
      a = va[i];
      b = vb[i];
      q_a.push_back(a);
      q_b.push_back(b);
      @(posedge clk);
    end
    #1 valid = 0;
    repeat (20) @(posedge clk);

    if (q_d.size() != va.size() || q_r.size() != va.size()) begin
      errs++;
      $display("[FAIL] results: fpMulWiden %0d, fp32Multiplier %0d, inputs %0d", q_d.size(), q_r.size(), va.size());
    end
    for (int i = 0; i < q_d.size() && i < q_r.size(); i++) begin
      checked++;
      if (q_d[i] !== q_r[i]) begin
        errs++;
        if (errs <= 20)
          $display("[FAIL] %h * %h: fpMulWiden %h (ov %b un %b inv %b), fp32Multiplier %h (ov %b un %b inv %b)",
                   q_a[i], q_b[i], q_d[i][34:3], q_d[i][2], q_d[i][1], q_d[i][0], q_r[i][34:3], q_r[i][2], q_r[i][1], q_r[i][0]);
      end
    end
    $display("fpMulWiden EXP_W=%0d MAN_W=%0d: %0d products checked against fp32Multiplier, %0d mismatches", EXP_W, MAN_W,
             checked, errs);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end

endmodule
