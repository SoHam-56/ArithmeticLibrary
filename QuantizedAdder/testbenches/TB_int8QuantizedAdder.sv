`timescale 1ns / 100ps

// int8QuantizedAdder against the C reference through DPI: every (q1, q2) under each +CONSTS set, then every +VEC row; latency QUANT_ADD_LATENCY (build at +define+FMT_INT8), a bubble every 64 beats; +DUMP writes each result.
module TB_int8QuantizedAdder;
  import "DPI-C" function int c_int8_quantized_add(input int q1, input int q2, input int z1, input int z2, input int m1, input int m2,
                                                   input int e, input int zo, input int lo, input int hi);
  localparam int LAT = sienna_fmt_pkg::QUANT_ADD_LATENCY;
  initial if (LAT == 0) $fatal(1, "TB_int8QuantizedAdder: QUANT_ADD_LATENCY is 0: build at +define+FMT_INT8");
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic [7:0] q1 = '0, q2 = '0, zp1 = '0, zp2 = '0, zpo = '0, amin = '0, amax = '0;
  logic [31:0] m1 = '0, m2 = '0;
  logic [5:0] shift = '0;
  logic [7:0] res;
  logic done;

  int8QuantizedAdder dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .q1_i(q1), .q2_i(q2), .zp1_i(zp1), .zp2_i(zp2), .m1_i(m1), .m2_i(m2),
      .shift_i(shift), .zpo_i(zpo), .act_min_i(amin), .act_max_i(amax), .result_o(res), .done_o(done));

  typedef struct {
    logic [7:0] q1, q2, z1, z2;
    logic [31:0] m1, m2;
    logic [5:0] e;
    logic [7:0] zo, lo, hi, want;
  } tx_t;
  tx_t q[$];
  longint checked = 0, errs = 0, issued = 0;
  int cyc = 0, t_issue = -1, lat = -1, dfd = 0;

  // The C reference on values worked by hand, before it judges the unit.
  task automatic known_values();
    if (c_int8_quantized_add(10, 10, 0, 0, 1 << 31, 1 << 31, 33, 0, -128, 127) != 5 ||  // (10 + 10) / 4
        c_int8_quantized_add(-3, -3, 0, 0, 1 << 31, 1 << 31, 33, 0, -128, 127) != -1 ||  // -1.5 rounds half up
        c_int8_quantized_add(50, 10, 40, 0, 1 << 31, 1 << 31, 33, 4, -128, 127) != 9 ||  // zero points
        c_int8_quantized_add(-100, -100, 0, 0, 1 << 31, 1 << 31, 32, 3, 3, 127) != 3 ||  // the clamp
        c_int8_quantized_add(127, 127, -128, -128, -1, -1, 9, 0, -128, 127) != 127 ||  // the widest sum saturates
        c_int8_quantized_add(-128, -128, 127, 127, -1, -1, 9, 0, -128, 127) != -128)
      $fatal(1, "TB_int8QuantizedAdder: the C reference fails a known value");
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
            $display("[FAIL] q %0d %0d zp %0d %0d m %h %h shift %0d zpo %0d clamp [%0d, %0d]: got %0d, reference %0d", $signed(t.q1),
                     $signed(t.q2), $signed(t.z1), $signed(t.z2), t.m1, t.m2, t.e, $signed(t.zo), $signed(t.lo), $signed(t.hi),
                     $signed(res), $signed(t.want));
        end
      end
    end
  end

  task automatic beat(input tx_t t);
    t.want = 8'(c_int8_quantized_add(int'($signed(t.q1)), int'($signed(t.q2)), int'($signed(t.z1)), int'($signed(t.z2)), int'(t.m1),
                                     int'(t.m2), int'(t.e), int'($signed(t.zo)), int'($signed(t.lo)), int'($signed(t.hi))));
    q.push_back(t);
    #1 valid = 1;
    {q1, q2, zp1, zp2, m1, m2, shift, zpo, amin, amax} = {t.q1, t.q2, t.z1, t.z2, t.m1, t.m2, t.e, t.zo, t.lo, t.hi};
    @(posedge clk);
    issued++;
    if (issued % 64 == 0) begin  // a bubble: the inputs change with valid_i low, and nothing may come out for it
      #1 valid = 0;
      {q1, q2, zp1, zp2} = $urandom;
      {m1, m2} = {$urandom, $urandom};
      {shift, zpo, amin, amax} = 30'($urandom);
      @(posedge clk);
    end
  endtask

  initial begin
    string consts, vec, dump;
    int fd, nf;
    tx_t t;
    known_values();
    if ($value$plusargs("DUMP=%s", dump)) dfd = $fopen(dump, "w");
    repeat (4) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    if ($value$plusargs("CONSTS=%s", consts)) begin
      fd = $fopen(consts, "r");
      if (fd == 0) $fatal(1, "TB_int8QuantizedAdder: cannot open %s", consts);
      while ($fscanf(fd, "%h %h %h %h %h %h %h %h\n", t.z1, t.z2, t.m1, t.m2, t.e, t.zo, t.lo, t.hi) == 8)
        for (int a = 0; a < 256; a++)
          for (int b = 0; b < 256; b++) begin
            t.q1 = 8'(a);
            t.q2 = 8'(b);
            beat(t);
          end
      $fclose(fd);
    end
    if (!$value$plusargs("VEC=%s", vec)) vec = "";
    if (vec != "") begin
      fd = $fopen(vec, "r");
      if (fd == 0) $fatal(1, "TB_int8QuantizedAdder: cannot open %s", vec);
      forever begin
        nf = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h\n", t.q1, t.q2, t.z1, t.z2, t.m1, t.m2, t.e, t.zo, t.lo, t.hi);
        if (nf != 10) break;
        beat(t);
      end
      $fclose(fd);
    end
    #1 valid = 0;
    repeat (LAT + 4) @(posedge clk);
    if (dfd != 0) $fclose(dfd);
    if (issued == 0) begin
      errs++;
      $display("[FAIL] no beats: give +CONSTS and/or +VEC");
    end
    if (checked != issued || q.size() != 0) begin
      errs++;
      $display("[FAIL] %0d beats issued, %0d results, %0d never came out", issued, checked, q.size());
    end
    if (lat != LAT) begin
      errs++;
      $display("[FAIL] latency %0d, sienna_fmt_pkg::QUANT_ADD_LATENCY says %0d", lat, LAT);
    end
    $display("int8QuantizedAdder: %0d beats against the %s, %0d errors, latency %0d", checked,
             "C reference",
             errs, lat);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
