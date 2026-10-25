`timescale 1ns / 100ps

// int32Adder (the accumulator add) against the C reference (int_ref_core.h) through DPI: wrap corners, corner pairs, carry chains,
// random pairs; +DUMP=<file> writes results.
module TB_int32Adder #(
    parameter int RANDOM = 1000000
);
  localparam int DATA_WIDTH = 32;
  import "DPI-C" function int c_int_add(input int a, input int b, input int w);
  localparam logic [DATA_WIDTH-1:0] ONE = DATA_WIDTH'(1);
  localparam logic [DATA_WIDTH-1:0] ONES = {DATA_WIDTH{1'b1}};
  localparam logic [DATA_WIDTH-1:0] MAX_VALUE = {1'b0, {(DATA_WIDTH - 1) {1'b1}}};
  localparam logic [DATA_WIDTH-1:0] MIN_VALUE = {1'b1, {(DATA_WIDTH - 1) {1'b0}}};
  // MAX+1, MIN-1, MIN+MIN, MAX+MAX, -1+1, MIN+MAX, with their sums worked by hand.
  localparam int KNOWN_COUNT = 6;
  localparam logic [DATA_WIDTH-1:0] KNOWN_A[KNOWN_COUNT] = '{MAX_VALUE, MIN_VALUE, MIN_VALUE, MAX_VALUE, ONES, MIN_VALUE};
  localparam logic [DATA_WIDTH-1:0] KNOWN_B[KNOWN_COUNT] = '{ONE, ONES, MIN_VALUE, MAX_VALUE, ONE, MAX_VALUE};
  localparam logic [DATA_WIDTH-1:0] KNOWN_SUM[KNOWN_COUNT] = '{MIN_VALUE, MAX_VALUE, '0, ONES - ONE, '0, ONES};
  localparam int CORNER_COUNT = 14;
  localparam logic [DATA_WIDTH-1:0] CORNER[CORNER_COUNT] = '{'0, ONE, ONES, ONE + ONE, ONES - ONE, MAX_VALUE, MIN_VALUE, MAX_VALUE - ONE, MIN_VALUE + ONE, {(DATA_WIDTH / 2) {2'b01}},
                                          {(DATA_WIDTH / 2) {2'b10}}, ONES >> (DATA_WIDTH / 2), ONES << (DATA_WIDTH / 2), ONE << (DATA_WIDTH / 2)};

  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic signed [DATA_WIDTH-1:0] a = '0, b = '0, res;
  logic done;
  int32Adder dut (.clk_i(clk), .rstn_i(rstn), .valid_i(valid), .a_i(a), .b_i(b), .result_o(res), .done_o(done));

  typedef struct {
    logic [DATA_WIDTH-1:0] a, b, res;
  } tx_t;
  tx_t q[$];
  logic [DATA_WIDTH-1:0] va[$], vb[$];
  longint checked = 0, errs = 0, idles = 0;
  int fd = 0, cyc = 0, t_issue = -1, lat = -1;
  string dump;

  function automatic void push(input logic [DATA_WIDTH-1:0] x, input logic [DATA_WIDTH-1:0] y);
    va.push_back(x);
    vb.push_back(y);
  endfunction

  task automatic build_stimulus();
    for (int i = 0; i < KNOWN_COUNT; i++) push(KNOWN_A[i], KNOWN_B[i]);
    for (int i = 0; i < CORNER_COUNT; i++)
      for (int j = 0; j < CORNER_COUNT; j++) push(CORNER[i], CORNER[j]);
    for (int k = 0; k < DATA_WIDTH; k++) begin  // carries rippling through k bits, borrows through the top, every power of two doubled
      push((ONE << k) - ONE, ONE);
      push(ONES << k, ONES);
      push(ONE << k, ONE << k);
    end
    for (int n = 0; n < RANDOM; n++)
      if (n % 4 == 0)
        push($urandom_range(0, 1) ? MAX_VALUE - DATA_WIDTH'($urandom_range(0, 255)) : MIN_VALUE + DATA_WIDTH'($urandom_range(0, 255)),
             DATA_WIDTH'($signed(9'($urandom_range(0, 511)))));  // within 255 of a rail, a step of -256..255
      else push(DATA_WIDTH'($urandom), DATA_WIDTH'($urandom));
  endtask

  task automatic drive(input logic [DATA_WIDTH-1:0] x, input logic [DATA_WIDTH-1:0] y);
    tx_t t;
    t.a = x;
    t.b = y;
    t.res = DATA_WIDTH'(c_int_add(int'(x), int'(y), DATA_WIDTH));
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
          if (errs <= 20) $display("[FAIL] %h + %h: got %h, reference %h", t.a, t.b, res, t.res);
        end
        if (fd != 0) $fwrite(fd, "%h %h %h\n", t.a, t.b, res);
      end
    end
  end

  initial begin
    for (int i = 0; i < KNOWN_COUNT; i++)
      if (DATA_WIDTH'(c_int_add(int'(KNOWN_A[i]), int'(KNOWN_B[i]), DATA_WIDTH)) !== KNOWN_SUM[i]) $fatal(1, "TB_int32Adder: the C reference fails known sum %0d", i);
    if ($value$plusargs("DUMP=%s", dump)) fd = $fopen(dump, "w");
    build_stimulus();
    repeat (8) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    foreach (va[i]) begin
      drive(va[i], vb[i]);
      if ($urandom_range(0, 7) == 0) idle();
    end
    #1 valid = 0;
    repeat (20) @(posedge clk);
    if (fd != 0) $fclose(fd);
    if (q.size() != 0) begin
      errs++;
      $display("[FAIL] %0d results never came out", q.size());
    end
    if (checked != va.size()) begin
      errs++;
      $display("[FAIL] %0d results for %0d inputs", checked, va.size());
    end
    if (lat != sienna_fmt_pkg::ADD_LATENCY) begin
      errs++;
      $display("[FAIL] latency %0d, sienna_fmt_pkg::ADD_LATENCY says %0d", lat, sienna_fmt_pkg::ADD_LATENCY);
    end
    $display("int32Adder: %0d sums against the C reference, %0d errors, latency %0d, %0d idle cycles", checked, errs, lat, idles);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
