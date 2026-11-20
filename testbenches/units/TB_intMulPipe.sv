`timescale 1ns / 100ps

// intMulPipe against a_i * b_i: every corner pair (the extremes, zero, plus and minus one, and their neighbours), then random pairs,
// back to back with a bubble every 17th issue; the latency must be STAGES. Build with -GAW= -GBW= -GSTAGES= for each use.
module TB_intMulPipe #(
    parameter int AW     = 16,
    parameter int BW     = 16,
    parameter int STAGES = 2,
    parameter int S1_LEVELS = -1,
    parameter int RANDOM = 20000
);
  localparam int W = AW + BW;
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;

  logic valid = 0;
  logic signed [AW-1:0] a = '0;
  logic signed [BW-1:0] b = '0;
  logic signed [W-1:0] res;
  logic done;
  intMulPipe #(.AW(AW), .BW(BW), .STAGES(STAGES), .S1_LEVELS(S1_LEVELS)) dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .a_i(a), .b_i(b), .result_o(res), .done_o(done));

  // Expected products in issue order; checked as done_o returns them.
  logic signed [W-1:0] exp_q[$];
  int checked = 0, errs = 0, cyc = 0, t_issue = -1, lat = -1;
  always @(posedge clk) begin
    cyc++;
    if (valid && t_issue < 0) t_issue = cyc;
    if (rstn && done) begin
      if (lat < 0) lat = cyc - t_issue;
      if (exp_q.size() == 0) begin
        errs++;
        if (errs < 10) $display("[FAIL] done_o with nothing issued at cycle %0d", cyc);
      end else begin
        automatic logic signed [W-1:0] e = exp_q.pop_front();
        checked++;
        if (res !== e) begin
          errs++;
          if (errs < 10) $display("[FAIL] product %0d: got %0d, expected %0d", checked, res, e);
        end
      end
    end
  end

  task automatic issue(input logic signed [AW-1:0] x, input logic signed [BW-1:0] y);
    @(posedge clk);
    #1 valid = 1; a = x; b = y;
    exp_q.push_back(W'(x) * W'(y));
  endtask
  task automatic bubble();
    @(posedge clk);
    #1 valid = 0; a = 'x; b = 'x;
  endtask

  localparam int NC = 7;
  function automatic logic signed [AW-1:0] ca(input int i);
    case (i)
      0: return {1'b1, {(AW - 1) {1'b0}}};        // most negative
      1: return {1'b1, {(AW - 2) {1'b0}}, 1'b1};  // its neighbour
      2: return -1;
      3: return 0;
      4: return 1;
      5: return {1'b0, {(AW - 2) {1'b1}}, 1'b0};  // largest minus one
      default: return {1'b0, {(AW - 1) {1'b1}}};  // largest
    endcase
  endfunction
  function automatic logic signed [BW-1:0] cb(input int i);
    case (i)
      0: return {1'b1, {(BW - 1) {1'b0}}};
      1: return {1'b1, {(BW - 2) {1'b0}}, 1'b1};
      2: return -1;
      3: return 0;
      4: return 1;
      5: return {1'b0, {(BW - 2) {1'b1}}, 1'b0};
      default: return {1'b0, {(BW - 1) {1'b1}}};
    endcase
  endfunction

  initial begin
    int n = 0;
    repeat (4) @(posedge clk);
    #1 rstn = 1;
    for (int i = 0; i < NC; i++)
      for (int j = 0; j < NC; j++) begin
        issue(ca(i), cb(j));
        if (++n % 17 == 0) bubble();
      end
    for (int k = 0; k < RANDOM; k++) begin
      issue(AW'($urandom()) ^ (AW'($urandom()) << 16), BW'($urandom()) ^ (BW'($urandom()) << 16));
      if (++n % 17 == 0) bubble();
    end
    bubble();
    repeat (STAGES + 4) @(posedge clk);
    if (exp_q.size() != 0) begin
      errs++;
      $display("[FAIL] %0d products never returned", exp_q.size());
    end
    if (lat != STAGES) begin
      errs++;
      $display("[FAIL] latency %0d, STAGES %0d", lat, STAGES);
    end
    $display("MULPIPE AW=%0d BW=%0d STAGES=%0d: %0d products, %0d errors, latency %0d", AW, BW, STAGES, checked, errs, lat);
    if (errs == 0 && checked == NC * NC + RANDOM) $display("RESULT: PASSED");
    else $display("RESULT: FAILED");
    $finish;
  end
endmodule
