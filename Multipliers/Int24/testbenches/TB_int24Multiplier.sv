`timescale 1ns / 100ps

// int24Multiplier (GPNAE's POSTM) against the C reference (int_ref_core.h) through DPI: every pair of corners and RANDOM pairs; +DUMP=<file> writes results.
module TB_int24Multiplier #(
    parameter int RANDOM = 1000000
);
  localparam int DATA_WIDTH = 24;
  import "DPI-C" function longint c_int_mul_wide(input longint a, input longint b, input int w);
  localparam logic [DATA_WIDTH-1:0] MX = {1'b0, {(DATA_WIDTH - 1) {1'b1}}};
  localparam logic [DATA_WIDTH-1:0] MN = {1'b1, {(DATA_WIDTH - 1) {1'b0}}};
  localparam int NC = 11;

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic signed [DATA_WIDTH-1:0] a = '0, b = '0;
  logic signed [2*DATA_WIDTH-1:0] res;
  logic done;
  int24Multiplier dut (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .a_i(a), .b_i(b), .result_o(res), .done_o(done));

  typedef struct {
    logic [DATA_WIDTH-1:0] a, b;
    logic [2*DATA_WIDTH-1:0] res;
  } tx_t;
  tx_t q[$];
  longint checked = 0, errs = 0, idles = 0, n_expect = 0;
  int fd = 0, cyc = 0, t_issue = -1, lat = -1;
  string dump;

  // The C reference on products worked by hand, before it judges the unit.
  task automatic known_values();
    if (c_int_mul_wide(-8388608, -8388608, 24) != 64'sd70368744177664 || c_int_mul_wide(-8388608, 8388607, 24) != -64'sd70368735789056 ||
        c_int_mul_wide(8388607, 8388607, 24) != 64'sd70368727400449 || c_int_mul_wide(-1, -1, 24) != 1)
      $fatal(1, "TB_int24Multiplier: the C reference fails a known product");
  endtask

  task automatic drive(input logic [DATA_WIDTH-1:0] x, input logic [DATA_WIDTH-1:0] y);
    tx_t t;
    t.a = x;
    t.b = y;
    t.res = (2 * DATA_WIDTH)'(c_int_mul_wide(longint'($signed(x)), longint'($signed(y)), DATA_WIDTH));
    q.push_back(t);
    #1 valid = 1;
    a = x;
    b = y;
    @(posedge clk);
  endtask

  // One cycle without valid_i, with junk on the operands.
  task automatic idle();
    #1 valid = 0;
    a = DATA_WIDTH'($urandom);
    b = DATA_WIDTH'($urandom);
    idles++;
    @(posedge clk);
  endtask

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (valid && t_issue < 0) t_issue = cyc;
    if (rstn && done) begin
      tx_t t;
      if (lat < 0) lat = cyc - t_issue;  // edges from the one that took valid_i to the one that sees done_o
      if (q.size() == 0) begin
        errs++;
        $display("[FAIL] a result with nothing issued");
      end else begin
        t = q.pop_front();
        checked++;
        if (res !== t.res) begin
          errs++;
          if (errs <= 20) $display("[FAIL] %h * %h: got %h, reference %h", t.a, t.b, res, t.res);
        end
        if (fd != 0) $fwrite(fd, "%h %h %h\n", t.a, t.b, res);
      end
    end
  end

  initial begin
    known_values();
    if ($value$plusargs("DUMP=%s", dump)) fd = $fopen(dump, "w");
    repeat (8) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    if (DATA_WIDTH <= 8) begin
      for (int x = 0; x < (1 << DATA_WIDTH); x++)
        for (int y = 0; y < (1 << DATA_WIDTH); y++) begin
          drive(DATA_WIDTH'(x), DATA_WIDTH'(y));
          if ($urandom_range(0, 7) == 0) idle();
        end
      n_expect = longint'(1) << (2 * DATA_WIDTH);
    end else begin  // every pair of corner values, then RANDOM random pairs
      logic [DATA_WIDTH-1:0] cv[NC];
      cv = '{'0, DATA_WIDTH'(1), '1, DATA_WIDTH'(2), DATA_WIDTH'(-2), MX, MN, MX - DATA_WIDTH'(1), MN + DATA_WIDTH'(1), {(DATA_WIDTH / 2) {2'b01}}, {(DATA_WIDTH / 2) {2'b10}}};
      foreach (cv[i])
        foreach (cv[j]) begin
          drive(cv[i], cv[j]);
          if ($urandom_range(0, 7) == 0) idle();
        end
      for (int n = 0; n < RANDOM; n++) begin
        drive(DATA_WIDTH'($urandom), DATA_WIDTH'($urandom));
        if ($urandom_range(0, 7) == 0) idle();
      end
      n_expect = NC * NC + RANDOM;
    end
    #1 valid = 0;
    repeat (20) @(posedge clk);
    if (fd != 0) $fclose(fd);
    if (q.size() != 0) begin
      errs++;
      $display("[FAIL] %0d results never came out", q.size());
    end
    if (checked != n_expect) begin
      errs++;
      $display("[FAIL] %0d results for %0d pairs", checked, n_expect);
    end
    if (lat != sienna_fmt_pkg::LANE_MUL_LATENCY) begin
      errs++;
      $display("[FAIL] latency %0d, sienna_fmt_pkg::LANE_MUL_LATENCY says %0d", lat, sienna_fmt_pkg::LANE_MUL_LATENCY);
    end
    $display("int24Multiplier: %0d products against the C reference, %0d errors, latency %0d, %0d idle cycles", checked, errs, lat, idles);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
