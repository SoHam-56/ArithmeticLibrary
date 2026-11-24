`timescale 1ns / 100ps
// mem_array's banked mappings against its flop array: the same random writes (masked) and reads go to IMPL FLOPS (SYNC_READ 1), SP and
// DP, kept each cycle to what the bank ports allow (SP: one access per bank; DP: one write and one read per bank, on different rows), and
// every read port's word must agree every cycle, including the held words of ports that did not read. FAULT 1 adds one illegal cycle
// (two reads in one SP bank, a read of the row being written in DP): a_bank_ports must fire, and the run reports it.
module TB_mem_banked #(
    parameter int DEPTH  = 64,
    parameter int WIDTH  = 32,
    parameter int MASK_W = 8,
    parameter int NW     = 2,
    parameter int NR     = 4,
    parameter int BANKS  = 4,
    parameter int STRIDE = 2,
    parameter int CYCLES = 20000,
    parameter int FAULT  = 0
);
  localparam int AW = $clog2(DEPTH);
  localparam int MU = WIDTH / MASK_W;
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic [NW-1:0]            we, we_sp, we_dp;
  logic [NW-1:0][AW-1:0]    waddr;
  logic [NW-1:0][MU-1:0]    wmask;
  logic [NW-1:0][WIDTH-1:0] wdata;
  logic [NR-1:0]            re, re_sp, re_dp;
  logic [NR-1:0][AW-1:0]    raddr;
  logic [NR-1:0][WIDTH-1:0] r_fl, r_sp, r_dp, r_fl2;

  // The reference for each mapping is a flop array fed exactly its legal accesses.
  mem_array #(.DEPTH(DEPTH), .WIDTH(WIDTH), .NW(NW), .NR(NR), .MASK_W(MASK_W), .ZERO_INIT(1'b1)) ref_sp (
      .clk_i(clk), .we_i(we_sp), .waddr_i(waddr), .wmask_i(wmask), .wdata_i(wdata), .re_i(re_sp), .raddr_i(raddr), .rdata_o(r_fl));
  mem_array #(.DEPTH(DEPTH), .WIDTH(WIDTH), .NW(NW), .NR(NR), .MASK_W(MASK_W), .ZERO_INIT(1'b1), .IMPL("SP"), .BANKS(BANKS),
              .BANK_STRIDE(STRIDE)) dut_sp (
      .clk_i(clk), .we_i(we_sp), .waddr_i(waddr), .wmask_i(wmask), .wdata_i(wdata), .re_i(re_sp), .raddr_i(raddr), .rdata_o(r_sp));
  mem_array #(.DEPTH(DEPTH), .WIDTH(WIDTH), .NW(NW), .NR(NR), .MASK_W(MASK_W), .ZERO_INIT(1'b1)) ref_dp (
      .clk_i(clk), .we_i(we_dp), .waddr_i(waddr), .wmask_i(wmask), .wdata_i(wdata), .re_i(re_dp), .raddr_i(raddr), .rdata_o(r_fl2));
  mem_array #(.DEPTH(DEPTH), .WIDTH(WIDTH), .NW(NW), .NR(NR), .MASK_W(MASK_W), .ZERO_INIT(1'b1), .IMPL("DP"), .BANKS(BANKS),
              .BANK_STRIDE(STRIDE)) dut_dp (
      .clk_i(clk), .we_i(we_dp), .waddr_i(waddr), .wmask_i(wmask), .wdata_i(wdata), .re_i(re_dp), .raddr_i(raddr), .rdata_o(r_dp));

  function automatic int bank_of(input int a);
    return (a / STRIDE) % BANKS;
  endfunction

  int errs = 0, n_w_sp = 0, n_r_sp = 0, n_w_dp = 0, n_r_dp = 0, cyc = 0;
  logic fault_now = 1'b0;

  // Random accesses, then each mapping keeps the legal subset (ports in order: a later port loses a conflict).
  always @(negedge clk) begin
    automatic int sp_used[BANKS], dp_w[BANKS], dp_r[BANKS];
    automatic int dp_wrow[BANKS];
    for (int b = 0; b < BANKS; b++) begin sp_used[b] = 0; dp_w[b] = 0; dp_r[b] = 0; dp_wrow[b] = -1; end
    for (int p = 0; p < NW; p++) begin
      we[p]    = ($urandom_range(0, 99) < 40);
      waddr[p] = AW'($urandom_range(0, DEPTH - 1));
      wmask[p] = MU'($urandom);
      wdata[p] = {$urandom, $urandom};
    end
    for (int p = 0; p < NR; p++) begin
      re[p]    = ($urandom_range(0, 99) < 50);
      raddr[p] = AW'($urandom_range(0, DEPTH - 1));
    end
    we_sp = '0; re_sp = '0; we_dp = '0; re_dp = '0;
    for (int p = 0; p < NW; p++) if (we[p]) begin
      automatic int b;
      b = bank_of(int'(waddr[p]));
      if (sp_used[b] == 0) begin we_sp[p] = 1'b1; sp_used[b] = 1; end
      if (dp_w[b] == 0) begin we_dp[p] = 1'b1; dp_w[b] = 1; dp_wrow[b] = int'(waddr[p]); end
    end
    for (int p = 0; p < NR; p++) if (re[p]) begin
      automatic int b;
      b = bank_of(int'(raddr[p]));
      if (sp_used[b] == 0) begin re_sp[p] = 1'b1; sp_used[b] = 1; end
      if (dp_r[b] == 0 && dp_wrow[b] != int'(raddr[p])) begin re_dp[p] = 1'b1; dp_r[b] = 1; end
    end
    // FAULT 1: at cycle 1000, two reads into SP bank 0 and a DP read of the row being written.
    fault_now = (FAULT == 1) && (cyc == 1000);
    if (fault_now) begin
      we_sp = '0; re_sp = '0; we_dp = '0; re_dp = '0;
      re_sp[0] = 1'b1; raddr[0] = '0;
      re_sp[1] = 1'b1; raddr[1] = AW'(BANKS * STRIDE);  // the same bank 0, another row
      we_dp[0] = 1'b1; waddr[0] = AW'(STRIDE * BANKS * 2); re_dp[2] = 1'b1; raddr[2] = waddr[0];
    end
  end

  // The words, every cycle after the first reads (a held word too).
  always @(posedge clk) begin
    cyc++;
    n_w_sp += $countones(we_sp); n_r_sp += $countones(re_sp); n_w_dp += $countones(we_dp); n_r_dp += $countones(re_dp);
    if (cyc > 2 && FAULT == 0)
      for (int p = 0; p < NR; p++) begin
        if (r_sp[p] !== r_fl[p]) begin
          errs++;
          if (errs <= 5) $display("MISMATCH SP cycle %0d port %0d: banked %h flops %h", cyc, p, r_sp[p], r_fl[p]);
        end
        if (r_dp[p] !== r_fl2[p]) begin
          errs++;
          if (errs <= 5) $display("MISMATCH DP cycle %0d port %0d: banked %h flops %h", cyc, p, r_dp[p], r_fl2[p]);
        end
      end
  end

  initial begin
    repeat (CYCLES) @(posedge clk);
    $display("TB_mem_banked DEPTH %0d WIDTH %0d MASK_W %0d NW %0d NR %0d BANKS %0d STRIDE %0d: %0d cycles, SP %0d writes %0d reads, DP %0d writes %0d reads, %0d mismatches",
             DEPTH, WIDTH, MASK_W, NW, NR, BANKS, STRIDE, cyc, n_w_sp, n_r_sp, n_w_dp, n_r_dp, errs);
    if (FAULT == 0 && errs == 0) $display("RESULT: PASSED");  // not a ternary string: xsim can pass it empty
    else if (FAULT == 0) $display("RESULT: FAILED");
    else $display("RESULT: FAULT RUN (a_bank_ports must have fired above)");
    $finish;
  end
endmodule
