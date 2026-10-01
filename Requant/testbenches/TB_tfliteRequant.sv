`timescale 1ns / 100ps

// tfliteRequant against ipu.requant's vectors, bit for bit, latency req_lat(), a bubble every 64 vectors; no DPI, so Vivado runs it too.
module TB_tfliteRequant #(
    parameter string ROUNDING = "DOUBLE"
);
  localparam int LAT = sienna_fmt_pkg::req_lat();  // tfliteRequant's latency
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic [31:0] acc = '0, mult = '0;
  logic [7:0] shift = '0, zp = '0, amin = '0, amax = '0;
  logic [7:0] res;
  logic done;

  tfliteRequant #(.ROUNDING(ROUNDING)) dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .acc_i(acc), .mult_i(mult), .shift_i(shift), .zp_i(zp),
      .act_min_i(amin), .act_max_i(amax), .result_o(res), .done_o(done));

  typedef struct {
    logic [31:0] acc, mult;
    logic [7:0] shift, zp, amin, amax, want;
  } tx_t;
  tx_t q[$];
  longint checked = 0, errs = 0, issued = 0;
  int cyc = 0, t_issue = -1, lat = -1;

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
        if (res !== t.want) begin
          errs++;
          if (errs <= 20)
            $display("[FAIL] acc %h mult %h shift %0d zp %0d clamp [%0d, %0d]: got %0d, ipu.requant %0d", t.acc, t.mult,
                     $signed(t.shift), $signed(t.zp), $signed(t.amin), $signed(t.amax), $signed(res), $signed(t.want));
        end
      end
    end
  end

  initial begin
    string vec;
    int fd;
    logic [31:0] fa, fm;
    logic [7:0] fs, fz, fl, fh, fw;
    tx_t t;
    if (!$value$plusargs("VEC=%s", vec)) vec = (ROUNDING == "SINGLE") ? "vectors_single.mem" : "vectors_double.mem";
    fd = $fopen(vec, "r");
    if (fd == 0) $fatal(1, "TB_tfliteRequant: cannot open %s", vec);
    repeat (4) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    while ($fscanf(fd, "%h %h %h %h %h %h %h\n", fa, fm, fs, fz, fl, fh, fw) == 7) begin
      t.acc = fa;
      t.mult = fm;
      t.shift = fs;
      t.zp = fz;
      t.amin = fl;
      t.amax = fh;
      t.want = fw;
      q.push_back(t);
      #1 valid = 1;
      {acc, mult, shift, zp, amin, amax} = {fa, fm, fs, fz, fl, fh};
      @(posedge clk);
      issued++;
      if (issued % 64 == 0) begin  // a bubble: the inputs change with valid_i low, and nothing may come out for it
        #1 valid = 0;
        {acc, mult} = {$urandom, $urandom};
        {shift, zp, amin, amax} = $urandom;
        @(posedge clk);
      end
    end
    $fclose(fd);
    #1 valid = 0;
    repeat (LAT + 4) @(posedge clk);
    if (issued == 0) begin
      errs++;
      $display("[FAIL] no vectors read from %s", vec);
    end
    if (checked != issued || q.size() != 0) begin
      errs++;
      $display("[FAIL] %0d vectors issued, %0d results, %0d never came out", issued, checked, q.size());
    end
    if (lat != LAT) begin
      errs++;
      $display("[FAIL] latency %0d, expected %0d", lat, LAT);
    end
    $display("tfliteRequant ROUNDING=%s: %0d vectors from %s, %0d errors, latency %0d", ROUNDING, checked, vec, errs, lat);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
