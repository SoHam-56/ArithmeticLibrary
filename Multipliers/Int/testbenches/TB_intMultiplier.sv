`timescale 1ns / 100ps

// intMultiplier against the C reference through DPI: every pair at W = 8, corners and RANDOM pairs at W = 16; +DUMP=<file> writes results.
module TB_intMultiplier #(
    parameter int W      = 8,
    parameter int RANDOM = 1000000
);
  import "DPI-C" function int c_int_mul(input int a, input int b, input int w);
  localparam logic [W-1:0] MX = {1'b0, {(W - 1) {1'b1}}};
  localparam logic [W-1:0] MN = {1'b1, {(W - 1) {1'b0}}};
  localparam int NC = 11;

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic signed [W-1:0] a = '0, b = '0;
  logic signed [2*W-1:0] res;
  logic done;
  intMultiplier #(.W(W)) dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .A(a), .B(b), .result_o(res), .done_o(done));

  typedef struct {
    logic [W-1:0] a, b;
    logic [2*W-1:0] res;
  } tx_t;
  tx_t q[$];
  longint checked = 0, errs = 0, idles = 0, n_expect = 0;
  int fd = 0, cyc = 0, t_issue = -1, lat = -1;
  string dump;

  // The C reference on products worked by hand, before it judges the unit.
  task automatic known_values();
    if (W == 8 && (c_int_mul(-128, -128, 8) != 16384 || c_int_mul(-128, 127, 8) != -16256 || c_int_mul(127, 127, 8) != 16129 ||
                   c_int_mul(-1, -1, 8) != 1 || c_int_mul(-1, 1, 8) != -1 || c_int_mul(0, -128, 8) != 0))
      $fatal(1, "TB_intMultiplier: the C reference fails a known product");
    if (W == 16 && (c_int_mul(-32768, -32768, 16) != 1073741824 || c_int_mul(-32768, 32767, 16) != -1073709056 ||
                    c_int_mul(32767, 32767, 16) != 1073676289 || c_int_mul(-1, -1, 16) != 1))
      $fatal(1, "TB_intMultiplier: the C reference fails a known W = 16 product");
  endtask

  task automatic drive(input logic [W-1:0] x, input logic [W-1:0] y);
    tx_t t;
    t.a = x;
    t.b = y;
    t.res = (2 * W)'(c_int_mul(int'($signed(x)), int'($signed(y)), W));
    q.push_back(t);
    #1 valid = 1;
    a = x;
    b = y;
    @(posedge clk);
  endtask

  // One cycle without valid_i, with junk on the operands.
  task automatic idle();
    #1 valid = 0;
    a = W'($urandom);
    b = W'($urandom);
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
    if (W > 16) $fatal(1, "TB_intMultiplier: the DPI reference returns a 32-bit int");
    known_values();
    if ($value$plusargs("DUMP=%s", dump)) fd = $fopen(dump, "w");
    repeat (8) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    if (W <= 8) begin
      for (int x = 0; x < (1 << W); x++)
        for (int y = 0; y < (1 << W); y++) begin
          drive(W'(x), W'(y));
          if ($urandom_range(0, 7) == 0) idle();
        end
      n_expect = longint'(1) << (2 * W);
    end else begin  // W = 16: every pair of corner values, then RANDOM random pairs
      logic [W-1:0] cv[NC];
      cv = '{'0, W'(1), '1, W'(2), W'(-2), MX, MN, MX - W'(1), MN + W'(1), {(W / 2) {2'b01}}, {(W / 2) {2'b10}}};
      foreach (cv[i])
        foreach (cv[j]) begin
          drive(cv[i], cv[j]);
          if ($urandom_range(0, 7) == 0) idle();
        end
      for (int n = 0; n < RANDOM; n++) begin
        drive(W'($urandom), W'($urandom));
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
    if (lat != sienna_fmt_pkg::mul_lat(0, 7)) begin
      errs++;
      $display("[FAIL] latency %0d, sienna_fmt_pkg::mul_lat(0, 7) says %0d", lat, sienna_fmt_pkg::mul_lat(0, 7));
    end
    $display("intMultiplier W=%0d: %0d products against the C reference, %0d errors, latency %0d, %0d idle cycles", W, checked,
             errs, lat, idles);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
