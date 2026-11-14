`timescale 1ns / 100ps

// mem_array against a behavioural model: random masked writes on every port (same-row collisions included, the higher port must win per unit),
// random reads on every port, the SYNC_READ hold on a disabled port. MODE 0: 1W1R sync, whole-row mask; 1: 2W4R sync, 8-bit mask units;
// 2: 3W2R combinational; 3: the $fatal of a mask that does not divide the row.
module TB_mem_array #(parameter int MODE = 0, parameter int CYCLES = 4000);
  localparam int DEPTH  = (MODE == 1) ? 64 : (MODE == 2) ? 37 : 16;
  localparam int WIDTH  = (MODE == 1) ? 128 : (MODE == 2) ? 24 : 32;
  localparam int NW     = (MODE == 1) ? 2 : (MODE == 2) ? 3 : 1;
  localparam int NR     = (MODE == 1) ? 4 : (MODE == 2) ? 2 : 1;
  localparam int MASK_W = (MODE == 1) ? 8 : (MODE == 3) ? 7 : WIDTH;
  localparam bit SYNC   = (MODE != 2);
  localparam int AW     = $clog2(DEPTH);
  localparam int MU     = WIDTH / MASK_W;

  logic clk = 0;
  always #5 clk = ~clk;

  logic [NW-1:0]            we;
  logic [NW-1:0][   AW-1:0] waddr;
  logic [NW-1:0][   MU-1:0] wmask;
  logic [NW-1:0][WIDTH-1:0] wdata;
  logic [NR-1:0]            re;
  logic [NR-1:0][   AW-1:0] raddr;
  logic [NR-1:0][WIDTH-1:0] rdata;

  mem_array #(.DEPTH(DEPTH), .WIDTH(WIDTH), .NW(NW), .NR(NR), .MASK_W(MASK_W), .SYNC_READ(SYNC), .ZERO_INIT(1)) dut (
      .clk_i(clk), .we_i(we), .waddr_i(waddr), .wmask_i(wmask), .wdata_i(wdata), .re_i(re), .raddr_i(raddr), .rdata_o(rdata));

  logic [WIDTH-1:0] model[DEPTH];
  logic [NR-1:0][WIDTH-1:0] held;  // what each sync port must show: the row at its last enabled read
  int errors = 0, reads = 0, collisions = 0, holds = 0;

  function automatic logic [WIDTH-1:0] rnd_row();
    logic [WIDTH-1:0] r;
    for (int b = 0; b < WIDTH; b++) r[b] = 1'($urandom_range(0, 1));
    return r;
  endfunction

  initial begin
    for (int i = 0; i < DEPTH; i++) model[i] = '0;
    we = '0; re = '0; waddr = '0; raddr = '0; wmask = '0; wdata = '0; held = '0;
    repeat (2) @(posedge clk);
    for (int c = 0; c < CYCLES; c++) begin
      // Drive the cycle's ports just after the edge.
      #1;
      for (int p = 0; p < NW; p++) begin
        we[p]    = $urandom_range(0, 2) != 0;
        waddr[p] = (p > 0 && $urandom_range(0, 3) == 0) ? waddr[0] : AW'($urandom_range(0, DEPTH - 1));  // collide with port 0 sometimes
        wmask[p] = ($urandom_range(0, 3) == 0) ? '1 : MU'({$urandom(), $urandom(), $urandom(), $urandom()});
        wdata[p] = rnd_row();
      end
      for (int p = 0; p < NR; p++) begin
        re[p]    = $urandom_range(0, 3) != 0;
        raddr[p] = AW'($urandom_range(0, DEPTH - 1));
      end
      if (!SYNC) begin
        #1;  // combinational: the rows are visible now, before any write this cycle
        for (int p = 0; p < NR; p++) begin
          reads++;
          if (rdata[p] !== model[raddr[p]]) begin
            errors++;
            if (errors < 10) $display("FAIL cycle %0d comb port %0d row %0d: got %h want %h", c, p, raddr[p], rdata[p], model[raddr[p]]);
          end
        end
      end
      @(posedge clk);
      // The edge: sync ports sample the rows as they were, then the writes land (higher port wins per unit).
      for (int p = 0; p < NR; p++)
        if (SYNC && re[p]) held[p] = model[raddr[p]];
        else if (SYNC) holds++;
      for (int p = 0; p < NW; p++)
        if (we[p]) begin
          for (int q = 0; q < p; q++) if (we[q] && waddr[q] == waddr[p]) collisions++;
          for (int u = 0; u < MU; u++)
            if (wmask[p][u]) model[waddr[p]][u*MASK_W+:MASK_W] = wdata[p][u*MASK_W+:MASK_W];
        end
      if (SYNC) begin
        #1;
        for (int p = 0; p < NR; p++) begin
          reads++;
          if (rdata[p] !== held[p]) begin
            errors++;
            if (errors < 10) $display("FAIL cycle %0d sync port %0d: got %h want %h (re %0d row %0d)", c, p, rdata[p], held[p], re[p], raddr[p]);
          end
        end
      end
    end
    $display("MEM_ARRAY MODE=%0d: %0d reads, %0d same-row write collisions, %0d held reads, %0d errors", MODE, reads, collisions, holds, errors);
    if (errors == 0 && reads > 0 && (NW == 1 || collisions > 0) && (!SYNC || holds > 0)) $display("RESULT: PASSED");
    else $display("RESULT: FAILED");
    $finish;
  end
endmodule
