`timescale 1ns / 100ps

// Checks fpNarrow: a corner table with hand-derived bf16 results, then every tie class and RANDOM LFSR values; +DUMP=<file> writes "x y" per line for check_fpu.py.
module TB_fpNarrow #(
    parameter int EXP_W  = 8,
    parameter int MAN_W  = 7,
    parameter int RANDOM = 1000000
);
  localparam int W = 1 + EXP_W + MAN_W;

  logic [31:0] x;
  logic [W-1:0] y;
  int fd = 0, errs = 0, n = 0, n_corner = 0;
  string dump;

  fpNarrow #(.EXP_W(EXP_W), .MAN_W(MAN_W)) dut (.x_i(x), .y_o(y));

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

  task automatic apply(input logic [31:0] v);
    x = v;
    #1;
    n++;
    if (fd != 0) $fwrite(fd, "%h %h\n", x, y);
  endtask

  initial begin
    automatic logic [31:0] lfsr = 32'hACE1_2468;
    if ($value$plusargs("DUMP=%s", dump)) fd = $fopen(dump, "w");
    for (int i = 0; i < NC; i++) begin
      apply(CX[i]);
      n_corner++;
      // bf16 has hand-derived results; fp32 (MAN_W 23) is the identity
      if ((MAN_W == 7 && y !== W'(CY[i])) || (MAN_W == 23 && y !== W'(CX[i]))) begin
        errs++;
        $display("[FAIL] corner %08h: got %h, want %h", CX[i], y, MAN_W == 7 ? W'(CY[i]) : W'(CX[i]));
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
    $display("fpNarrow EXP_W=%0d MAN_W=%0d: %0d corners checked, %0d errors; %0d values in all (tie sweep 196608, random %0d)%s",
             EXP_W, MAN_W, n_corner, errs, n, RANDOM, fd != 0 ? string'(", dumped") : string'(", no dump"));
    // without a dump the tie sweep and random values go unchecked, so that is no pass
    $display("RESULT: %s", errs == 0 && fd != 0 ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
