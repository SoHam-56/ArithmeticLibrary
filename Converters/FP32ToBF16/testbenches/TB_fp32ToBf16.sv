`timescale 1ns / 100ps

// fp32ToBf16 against round to nearest even written from its definition, on every value: a corner table with hand-derived bf16 results,
// every tie class, RANDOM LFSR values; +DUMP=<file> writes "x y" per line for check_fpu.py (fpu.narrow, a second reference).
module TB_fp32ToBf16 #(
    parameter int RANDOM = 1000000
);
  localparam int DATA_WIDTH = 16;

  logic [31:0] x;
  logic [DATA_WIDTH-1:0] y;
  int fd = 0, errs = 0, n = 0, n_corner = 0, n_rne = 0;
  string dump;

  fp32ToBf16 dut (.fp32_i(x), .bf16_o(y));

  // fp32 bits, bf16 result: the table of test_fpu.py.
  localparam int NC = 27;
  localparam logic [31:0] CX[NC] = '{
      32'h00000000, 32'h80000000, 32'h00000001, 32'h807FFFFF, 32'h007FFFFF, 32'h00800000, 32'h0080FFFF,
      32'h3F800000, 32'h3F807FFF, 32'h3F808000, 32'h3F808001, 32'h3F818000, 32'hBF808000, 32'hBF818000,
      32'h3FFFFFFF, 32'h7F7F7FFF, 32'h7F7F8000, 32'h7F7FFFFF, 32'hFF7F8000, 32'hFF7FFFFF, 32'h7F800000,
      32'hFF800000, 32'h7FC00000, 32'hFFC00001, 32'h7F800001, 32'h7FBF8000, 32'h7FFFFFFF};
  localparam logic [15:0] CY[NC] = '{
      16'h0000, 16'h8000, 16'h0000, 16'h8000, 16'h0000, 16'h0080, 16'h0081,
      16'h3F80, 16'h3F80, 16'h3F80, 16'h3F81, 16'h3F82, 16'hBF80, 16'hBF82,
      16'h4000, 16'h7F7F, 16'h7F80, 16'h7F80, 16'hFF80, 16'hFF80, 16'h7F80,
      16'hFF80, 16'h7FC0, 16'h7FC0, 16'h7FC0, 16'h7FC0, 16'h7FC0};

  // Round to nearest even of the 16 dropped bits; NaN to the canonical qNaN, exponent 0 (zero or subnormal) to a signed zero.
  function automatic logic [15:0] rne(input logic [31:0] v);
    if ((v[30:23] == 8'hFF) && (v[22:0] != '0)) return 16'h7FC0;
    if (v[30:23] == 8'h00) return {v[31], 15'd0};
    return 16'((33'(v) + 33'h7FFF + 33'(v[16])) >> 16);  // a carry moves into the exponent, and past the largest value to infinity
  endfunction

  task automatic apply(input logic [31:0] v);
    x = v;
    #1;
    n++;
    n_rne++;
    if (y !== rne(v)) begin
      errs++;
      if (errs <= 20) $display("[FAIL] %08h: got %h, round to nearest even %h", v, y, rne(v));
    end
    if (fd != 0) $fwrite(fd, "%h %h\n", x, y);
  endtask

  initial begin
    automatic logic [31:0] lfsr = 32'hACE1_2468;
    if ($value$plusargs("DUMP=%s", dump)) fd = $fopen(dump, "w");
    for (int i = 0; i < NC; i++) begin
      apply(CX[i]);
      n_corner++;
      if (y !== CY[i]) begin
        errs++;
        $display("[FAIL] corner %08h: got %h, want %h", CX[i], y, CY[i]);
      end
    end
    // every upper half with the dropped bits just below, at and just above the tie
    for (int hi = 0; hi < 65536; hi++) begin
      apply({16'(hi), 16'h7FFF});
      apply({16'(hi), 16'h8000});
      apply({16'(hi), 16'h8001});
    end
    // Galois LFSR, taps 32 22 2 1
    for (int i = 0; i < RANDOM; i++) begin
      lfsr = lfsr[0] ? (lfsr >> 1) ^ 32'h8020_0003 : lfsr >> 1;
      apply(lfsr);
    end
    if (fd != 0) $fclose(fd);
    $display("fp32ToBf16: %0d corners against their table, %0d values against round to nearest even (tie sweep 196608, random %0d), %0d errors%s",
             n_corner, n_rne, RANDOM, errs, fd != 0 ? string'(", dumped") : string'(", no dump"));
    $display("RESULT: %s", errs == 0 && n_rne == n ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
