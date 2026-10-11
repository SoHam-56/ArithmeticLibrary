`timescale 1ns / 100ps

// tfliteAdd against ipu.tflite_add: +VEC= vectors with expected results, or +CONSTS= sets run over every (q1, q2) into +DUMP= for check_add.py; +N= the file's row count; a bubble every 64; every done_o qadd_lat() edges after its valid_i, result_o held while done_o is low; no DPI, so Vivado runs it too.
module TB_tfliteAdd #(
    parameter string ROUNDING = "DOUBLE"
);
  localparam int LAT = sienna_fmt_pkg::qadd_lat();
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  logic valid = 0;
  logic [7:0] q1 = '0, q2 = '0, zp1 = '0, zp2 = '0, s1 = '0, s2 = '0, so = '0, zpo = '0, amin = '0, amax = '0;
  logic [31:0] m1 = '0, m2 = '0, mo = '0;
  logic [7:0] res;
  logic done;

  tfliteAdd #(.ROUNDING(ROUNDING)) dut (
      .clk_i(clk), .rstn_i(rstn), .valid_i(valid), .q1_i(q1), .q2_i(q2), .zp1_i(zp1), .zp2_i(zp2), .m1_i(m1), .m2_i(m2),
      .mo_i(mo), .s1_i(s1), .s2_i(s2), .so_i(so), .zpo_i(zpo), .min_i(amin), .max_i(amax), .result_o(res), .done_o(done));

  typedef struct packed {
    logic [7:0] q1, q2, zp1, zp2;
    logic [31:0] m1;
    logic [7:0] s1;
    logic [31:0] m2;
    logic [7:0] s2;
    logic [31:0] mo;
    logic [7:0] so, zpo, amin, amax;
  } vec_t;
  logic [7:0] want_q[$];  // vector mode: the expected results, in issue order
  int t_q[$];  // the edge that took each beat's valid_i, in issue order
  bit dump_mode = 0;
  int fd_dump = 0;
  longint checked = 0, errs = 0, issued = 0, lat_errs = 0, val_errs = 0, orphans = 0, unexpected = 0, hold_errs = 0;
  logic [7:0] res_last;  // result_o at the previous edge
  int cyc = 0, lat = -1;

  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (valid) t_q.push_back(cyc);
    if (rstn && !done && cyc > 0 && res !== res_last) begin  // result_o may change only with done_o
      errs++;
      hold_errs++;
      if (hold_errs <= 20) $display("[FAIL] result_o changed from %0d to %0d with done_o low (edge %0d)", $signed(res_last), $signed(res), cyc);
    end
    res_last = res;
    if (rstn && done) begin
      if (t_q.size() == 0) begin
        errs++;
        orphans++;
        if (orphans <= 20) $display("[FAIL] a result with nothing issued");
      end else begin
        automatic int l = cyc - t_q.pop_front();  // edges from the one that took valid_i to the one that sees done_o
        if (lat < 0) lat = l;
        if (l != LAT) begin
          errs++;
          lat_errs++;
          if (lat_errs <= 20) $display("[FAIL] result %0d: done_o %0d edges after its valid_i, expected %0d", checked, l, LAT);
        end
      end
      checked++;
      if (dump_mode) begin
        $fwrite(fd_dump, "%02x", res);
        if (checked % 32 == 0) $fwrite(fd_dump, "\n");
      end else if (want_q.size() == 0) begin
        errs++;
        unexpected++;
        if (unexpected <= 20) $display("[FAIL] a result with no expected value");
      end else begin
        automatic logic [7:0] w = want_q.pop_front();
        if (res !== w) begin
          errs++;
          val_errs++;
          if (val_errs <= 20) $display("[FAIL] vector %0d: got %0d, ipu.tflite_add %0d", checked - 1, $signed(res), $signed(w));
        end
      end
    end
  end

  // One vector on valid_i; every 64th is followed by a bubble whose inputs change with valid_i low, and nothing may come out for it.
  task automatic issue(input vec_t v);
    #1 valid = 1;
    {q1, q2, zp1, zp2, m1, s1, m2, s2, mo, so, zpo, amin, amax} = v;
    @(posedge clk);
    issued++;
    if (issued % 64 == 0) begin
      #1 valid = 0;
      {q1, q2, zp1, zp2, m1, s1, m2, s2, mo, so, zpo, amin, amax} = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
      @(posedge clk);
    end
  endtask

  // A file line's words in column order (q1 q2, then gen_add_vectors.FIELDS) as a vector.
  function automatic vec_t vec_of(input logic [31:0] f[13]);
    return {f[0][7:0], f[1][7:0], f[2][7:0], f[3][7:0], f[4], f[5][7:0], f[6], f[7][7:0], f[8], f[9][7:0], f[10][7:0], f[11][7:0],
            f[12][7:0]};
  endfunction

  initial begin
    string vec, consts, dump;
    int fd, n_sets = 0, rc, n_want = -1;
    longint n_rows;
    logic [31:0] f[13], w;
    repeat (4) @(posedge clk);
    #1 rstn = 1;
    repeat (2) @(posedge clk);
    if ($value$plusargs("CONSTS=%s", consts)) begin
      if (!$value$plusargs("DUMP=%s", dump)) $fatal(1, "TB_tfliteAdd: +CONSTS needs +DUMP");
      dump_mode = 1;
      fd = $fopen(consts, "r");
      fd_dump = $fopen(dump, "w");
      if (fd == 0 || fd_dump == 0) $fatal(1, "TB_tfliteAdd: cannot open %s or %s", consts, dump);
      forever begin
        rc = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h\n", f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12]);
        if (rc != 11) break;
        n_sets++;
        for (int i = 0; i < 65536; i++) begin
          f[0] = 32'((i >> 8) - 128);  // q1 outer, q2 inner: gen_add_vectors.Q1, Q2
          f[1] = 32'((i & 255) - 128);
          issue(vec_of(f));
        end
      end
    end else begin
      if (!$value$plusargs("VEC=%s", vec)) vec = (ROUNDING == "SINGLE") ? "vectors_single.mem" : "vectors_double.mem";
      fd = $fopen(vec, "r");
      if (fd == 0) $fatal(1, "TB_tfliteAdd: cannot open %s", vec);
      forever begin
        rc = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h\n", f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11],
                     f[12], w);
        if (rc != 14) break;
        want_q.push_back(w[7:0]);
        issue(vec_of(f));
      end
    end
    n_rows = dump_mode ? n_sets : issued;
    if (!(rc == -1 || (rc == 0 && $feof(fd)))) begin  // IEEE gives -1 at end of file; Verilator 5.035 gives 0 with $feof set
      errs++;
      $display("[FAIL] %s: row %0d holds %0d fields or is not hex; the file was read only up to it", dump_mode ? consts : vec, n_rows + 1, rc);
    end
    if ($value$plusargs("N=%d", n_want) && longint'(n_want) != n_rows) begin
      errs++;
      $display("[FAIL] %0d rows read, +N= says the file holds %0d", n_rows, n_want);
    end else if (n_want < 0) $display("TB_tfliteAdd: no +N= given, the row count is unchecked");
    $fclose(fd);
    #1 valid = 0;
    repeat (LAT + 4) @(posedge clk);
    if (dump_mode) $fclose(fd_dump);
    if (issued == 0) begin
      errs++;
      $display("[FAIL] no vectors read");
    end
    if (checked != issued || want_q.size() != 0 || t_q.size() != 0 || (dump_mode && checked != longint'(n_sets) * 65536)) begin
      errs++;
      $display("[FAIL] %0d vectors issued, %0d results, %0d never came out", issued, checked, t_q.size());
    end
    if (lat != LAT) begin
      errs++;
      $display("[FAIL] latency %0d, expected %0d", lat, LAT);
    end
    if (lat_errs != 0) $display("[FAIL] %0d results whose done_o was not %0d edges after their valid_i", lat_errs, LAT);
    if (val_errs != 0) $display("[FAIL] %0d results differ from ipu.tflite_add", val_errs);
    if (hold_errs != 0) $display("[FAIL] result_o changed %0d times with done_o low", hold_errs);
    if (orphans + unexpected != 0) $display("[FAIL] %0d results with nothing issued, %0d with no expected value", orphans, unexpected);
    if (dump_mode) $display("tfliteAdd ROUNDING=%s: %0d results of %0d constant sets dumped to %s, %0d errors, latency %0d", ROUNDING, checked, n_sets, dump, errs, lat);
    else $display("tfliteAdd ROUNDING=%s: %0d vectors from %s, %0d errors, latency %0d", ROUNDING, checked, vec, errs, lat);
    $display("RESULT: %s", errs == 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
