`timescale 1ns / 100ps

// int8Requantizer against the C reference through DPI on every row of +VEC, latency REQUANT_LATENCY (build at +define+FMT_INT8), a bubble every 64 rows; +DUMP writes each result.
module TB_int8Requantizer;
  import "DPI-C" function int c_int8_requantize(input int acc, input int m, input int e, input int zp, input int lo, input int hi);
  localparam int LAT = sienna_fmt_pkg::REQUANT_LATENCY;
  initial if (LAT == 0) $fatal(1, "TB_int8Requantizer: REQUANT_LATENCY is 0: build at +define+FMT_INT8");
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic [31:0] acc = '0;
  logic [23:0] mult = '0;
  logic [5:0] shift = '0;
  logic [7:0] zp = '0, amin = '0, amax = '0;
  logic [7:0] res;
  logic done;

  int8Requantizer dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .acc_i(acc), .mult_i(mult), .shift_i(shift), .zp_i(zp),
      .act_min_i(amin), .act_max_i(amax), .result_o(res), .done_o(done));

  typedef struct {
    logic [31:0] acc;
    logic [23:0] mult;
    logic [5:0] shift;
    logic [7:0] zp, amin, amax, want;
  } tx_t;
  tx_t q[$];
  longint checked = 0, errs = 0, issued = 0;
  int cyc = 0, t_issue = -1, lat = -1, dfd = 0;

  // The C reference on values worked by hand, before it judges the unit.
  task automatic known_values();
    if (c_int8_requantize(100, 1 << 23, 24, 0, -128, 127) != 50 || c_int8_requantize(101, 1 << 23, 24, 0, -128, 127) != 51 ||
        c_int8_requantize(-101, 1 << 23, 24, 0, -128, 127) != -50 || c_int8_requantize(-3, 1 << 23, 24, 7, -128, 127) != 6 ||
        c_int8_requantize(1000, 1 << 23, 23, 0, -128, 127) != 127 || c_int8_requantize(-1000, 1 << 23, 23, -5, -5, 127) != -5 ||
        c_int8_requantize(32'h8000_0000, 24'hFF_FFFF, 0, 0, -128, 127) != -128 || c_int8_requantize(7, 0, 55, -9, -128, 127) != -9)
      $fatal(1, "TB_int8Requantizer: the C reference fails a known value");
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
        if (dfd != 0) $fwrite(dfd, "%h\n", res);
        if (res !== t.want) begin
          errs++;
          if (errs <= 20)
            $display("[FAIL] acc %h mult %h shift %0d zp %0d clamp [%0d, %0d]: got %0d, reference %0d", t.acc, t.mult, t.shift,
                     $signed(t.zp), $signed(t.amin), $signed(t.amax), $signed(res), $signed(t.want));
        end
      end
    end
  end

  initial begin
    string vec, dump;
    int fd, nf;
    logic [31:0] fa;
    logic [23:0] fm;
    logic [5:0] fs;
    logic [7:0] fz, fl, fh, fw;
    tx_t t;
    known_values();
    if (!$value$plusargs("VEC=%s", vec)) $fatal(1, "TB_int8Requantizer: +VEC=<row file> is required");
    if ($value$plusargs("DUMP=%s", dump)) dfd = $fopen(dump, "w");
    fd = $fopen(vec, "r");
    if (fd == 0) $fatal(1, "TB_int8Requantizer: cannot open %s", vec);
    repeat (4) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    forever begin
      nf = $fscanf(fd, "%h %h %h %h %h %h\n", fa, fm, fs, fz, fl, fh);
      if (nf != 6) break;
      fw = 8'(c_int8_requantize(int'($signed(fa)), int'(fm), int'(fs), int'($signed(fz)), int'($signed(fl)), int'($signed(fh))));
      t = '{acc: fa, mult: fm, shift: fs, zp: fz, amin: fl, amax: fh, want: fw};
      q.push_back(t);
      #1 valid = 1;
      {acc, mult, shift, zp, amin, amax} = {fa, fm, fs, fz, fl, fh};
      @(posedge clk);
      issued++;
      if (issued % 64 == 0) begin  // a bubble: the inputs change with valid_i low, and nothing may come out for it
        #1 valid = 0;
        {acc, mult} = {$urandom, 24'($urandom)};
        {shift, zp, amin, amax} = 30'($urandom);
        @(posedge clk);
      end
    end
    $fclose(fd);
    #1 valid = 0;
    repeat (LAT + 4) @(posedge clk);
    if (dfd != 0) $fclose(dfd);
    if (issued == 0) begin
      errs++;
      $display("[FAIL] no rows read from %s", vec);
    end
    if (checked != issued || q.size() != 0) begin
      errs++;
      $display("[FAIL] %0d rows issued, %0d results, %0d never came out", issued, checked, q.size());
    end
    if (lat != LAT) begin
      errs++;
      $display("[FAIL] latency %0d, sienna_fmt_pkg::REQUANT_LATENCY says %0d", lat, LAT);
    end
    $display("int8Requantizer: %0d rows from %s against the %s, %0d errors, latency %0d", checked, vec,
             "C reference",
             errs, lat);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
