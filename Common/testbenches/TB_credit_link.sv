`timescale 1ns / 100ps

// Sends 0, 1, 2, ... up to ITEMS while it holds a credit and its random gate allows; VIOLATE puts once without a credit, BYPASS counts without credit_counter.
module credit_tb_producer #(parameter int ITEMS = 1000, parameter int MAX = 32, parameter int SEED = 1, parameter bit VIOLATE = 0,
                            parameter bit BYPASS = 0, parameter int CRW = 6) (
    input logic clk_i, rstn_i,
    credit_link_if.producer lnk,
    output logic done_o, injected_o
);
  localparam int CW = $clog2(MAX + 1);
  logic has_credit;
  logic [CW-1:0] count;
  logic [31:0] sent, lfsr;
  logic vdone;
  wire viol = VIOLATE && !vdone && !has_credit && (lnk.credit != '0);
  wire want = (sent < ITEMS) && lfsr[0];
  assign lnk.put = (want && has_credit) || viol;
  assign lnk.data = sent;
  assign done_o = sent == ITEMS;
  assign injected_o = vdone;
  if (BYPASS) begin : g_plain
    always_ff @(posedge clk_i or negedge rstn_i)
      if (!rstn_i) count <= '0;
      else count <= count + CW'(lnk.credit) - CW'(lnk.put);
    assign has_credit = count != '0;
  end else begin : g_cc
    credit_counter #(.MAX(MAX), .CRW(CRW)) cc (.clk_i, .rstn_i, .put_i(lnk.put), .credit_i(lnk.credit), .has_credit_o(has_credit),
                                              .count_o(count));
  end
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) begin sent <= '0; lfsr <= 32'(SEED) | 32'h1; vdone <= 1'b0; end
    else begin
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      if (lnk.put) sent <= sent + 1;
      if (viol) vdone <= 1'b1;
    end
endmodule

// A SLOTS-deep FIFO: advertises SLOTS after reset, pops at a random rate, returns a credit per pop; OVER advertises one too many, LEAK keeps one credit.
module credit_tb_consumer #(parameter int SLOTS = 32, parameter int SEED = 7, parameter bit OVER = 0, parameter bit LEAK = 0,
                            parameter int CRW = 6) (
    input logic clk_i, rstn_i,
    credit_link_if.consumer lnk,
    output logic [31:0] got_o,
    output logic err_o, injected_o
);
  localparam int CW = $clog2(SLOTS + 1);
  logic [31:0] mem [SLOTS];
  logic [$clog2(SLOTS)-1:0] wp, rp;
  logic [CW-1:0] cnt;
  logic [31:0] lfsr;
  logic adv;     // the one-cycle advertisement after reset
  logic leaked;  // the leak has happened
  wire pop = cnt != 0 && lfsr[2];
  wire keep = (LEAK || OVER) && !leaked;
  assign injected_o = OVER || leaked;
  assign lnk.credit = adv ? CRW'(SLOTS + (OVER ? 1 : 0)) : CRW'(pop && !keep);  // the advertisement, then one credit per pop
  always_ff @(posedge clk_i or negedge rstn_i)
    if (!rstn_i) begin wp <= '0; rp <= '0; cnt <= '0; got_o <= '0; err_o <= 1'b0; lfsr <= 32'(SEED) | 32'h1; adv <= 1'b1; leaked <= 1'b0; end
    else begin
      adv <= 1'b0;
      lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
      if (lnk.put) begin
        if (cnt == CW'(SLOTS) && !pop) err_o <= 1'b1;  // overrun
        mem[wp] <= lnk.data; wp <= wp + 1'b1;
      end
      if (pop) begin
        if (mem[rp] != got_o) err_o <= 1'b1;  // out of order or corrupted
        got_o <= got_o + 1; rp <= rp + 1'b1;
        if (keep) leaked <= 1'b1;
      end
      cnt <= cnt + CW'(lnk.put) - CW'(pop);
    end
endmodule

// LANES credit links with random rates and a checker at both ends, plus a hand-driven link that frees 3 slots in one cycle; MODE 0 is normal, 1-4 put one fault on lane 0.
module TB_credit_link;
  parameter int LANES = 128, SLOTS = 32, ITEMS = 2000, STAGES = 0, MODE = 0;
  localparam int CRW = $clog2(SLOTS + 1);
  logic clk = 0, rstn = 0;
  always #5 clk = ~clk;
  credit_link_if #(.DATA_W(32), .CRW(CRW)) lp[LANES] ();
  credit_link_if #(.DATA_W(32), .CRW(CRW)) lc[LANES] ();
  logic [LANES-1:0] pdone, perr_inj, cinj, err;
  logic [31:0] got[LANES];
  logic [LANES-1:0] drained;  // per lane: all its items delivered and the last credit back
  for (genvar i = 0; i < LANES; i++) begin : g_lane
    localparam bit FAULT = (i == 0);
    credit_tb_producer #(.ITEMS(ITEMS), .MAX(SLOTS), .SEED(i * 37 + 5), .VIOLATE(FAULT && (MODE == 1 || MODE == 4)),
                         .BYPASS(FAULT && MODE == 4), .CRW(CRW)) p (
        .clk_i(clk), .rstn_i(rstn), .lnk(lp[i]), .done_o(pdone[i]), .injected_o(perr_inj[i]));
    credit_reg #(.STAGES(STAGES), .DATA_W(32), .CRW(CRW)) r (.clk_i(clk), .rstn_i(rstn), .up(lp[i]), .dn(lc[i]));
    credit_tb_consumer #(.SLOTS(SLOTS), .SEED(i * 11 + 3), .OVER(FAULT && MODE == 2), .LEAK(FAULT && MODE == 3), .CRW(CRW)) c (
        .clk_i(clk), .rstn_i(rstn), .lnk(lc[i]), .got_o(got[i]), .err_o(err[i]), .injected_o(cinj[i]));
    int settle;
    always_ff @(posedge clk or negedge rstn)
      if (!rstn) begin settle <= 0; drained[i] <= 1'b0; end
      else if (got[i] == ITEMS) begin
        if (settle == STAGES + 4) drained[i] <= 1'b1;
        else settle <= settle + 1;
      end
    credit_link_checker #(.SLOTS(SLOTS)) chk_p (.clk_i(clk), .rstn_i(rstn), .drained_i(drained[i]), .lnk(lp[i]));
    credit_link_checker #(.SLOTS(SLOTS)) chk_c (.clk_i(clk), .rstn_i(rstn), .drained_i(drained[i]), .lnk(lc[i]));
  end

  // The hand-driven link: the testbench puts and grants, a credit_counter at the producer end counts.
  credit_link_if #(.DATA_W(32), .CRW(CRW)) bp ();
  credit_link_if #(.DATA_W(32), .CRW(CRW)) bc ();
  logic bhas, bdrained;
  logic [$clog2(SLOTS+1)-1:0] bcount;
  credit_reg #(.STAGES(STAGES), .DATA_W(32), .CRW(CRW)) br (.clk_i(clk), .rstn_i(rstn), .up(bp), .dn(bc));
  credit_counter #(.MAX(SLOTS), .CRW(CRW)) bcnt (.clk_i(clk), .rstn_i(rstn), .put_i(bp.put), .credit_i(bp.credit), .has_credit_o(bhas),
                                                .count_o(bcount));
  credit_link_checker #(.SLOTS(SLOTS)) bchk_p (.clk_i(clk), .rstn_i(rstn), .drained_i(bdrained), .lnk(bp));
  credit_link_checker #(.SLOTS(SLOTS)) bchk_c (.clk_i(clk), .rstn_i(rstn), .drained_i(bdrained), .lnk(bc));

  int burst_bad;
  logic burst_done;
  task automatic cycles(input int n);
    repeat (n) @(negedge clk);  // the hand-driven link changes between clock edges
  endtask
  task automatic expect_count(input string what, input int want);
    cycles(STAGES + 4);
    if (int'(bcount) != want) begin
      burst_bad++;
      $display("[FAIL] burst link %s: count %0d, want %0d", what, bcount, want);
    end
  endtask
  initial begin
    burst_bad = 0; burst_done = 0; bdrained = 0; bp.put = 0; bp.data = '0; bc.credit = '0;
    wait (rstn);
    cycles(2);
    bc.credit <= CRW'(SLOTS); cycles(1); bc.credit <= '0;      // the advertisement
    expect_count("after advertisement", SLOTS);
    bp.put <= 1; cycles(5); bp.put <= 0;                       // 5 puts
    expect_count("after 5 puts", SLOTS - 5);
    bc.credit <= CRW'(3); cycles(1); bc.credit <= '0;          // 3 slots freed in one cycle
    expect_count("after 3 slots freed in one cycle", SLOTS - 2);
    bp.put <= 1; cycles(3); bp.put <= 0;                       // 3 more puts
    expect_count("after 3 more puts", SLOTS - 5);
    bp.put <= 1; bc.credit <= CRW'(3); cycles(1); bp.put <= 0; bc.credit <= '0;  // a put and 3 freed slots in the same cycle
    expect_count("after a put with 3 slots freed", SLOTS - 3);
    bc.credit <= CRW'(3); cycles(1); bc.credit <= '0;          // the last 3 slots back
    expect_count("all slots back", SLOTS);
    burst_done = 1; bdrained = 1;
  end

  int cyc, done_lanes, bad, injected;
  initial begin
    repeat (3) @(posedge clk);
    @(negedge clk);
    rstn = 1;  // released between edges so the first credits are seen with the assertions enabled
    cyc = 0;
    while (cyc < 200000) begin
      @(posedge clk);
      cyc++;
      done_lanes = 0;
      for (int i = 0; i < LANES; i++) if (got[i] == ITEMS) done_lanes++;
      // in the fault modes the run ends with lane 0, so its assertions fire a bounded number of times
      if ((MODE == 0 ? done_lanes == LANES : got[0] == ITEMS) && burst_done) break;
    end
    repeat (STAGES + 8) @(posedge clk);  // every finished lane has been drained for a few cycles
    bad = 0;
    for (int i = 0; i < LANES; i++) if (err[i] || got[i] != ITEMS) bad++;  // meaningful in mode 0 only
    injected = int'($countones(perr_inj)) + int'($countones(cinj));
    if (MODE == 0)
      $display("CREDIT_LINK STAGES=%0d MODE=%0d: %0d lanes delivered %0d items in order, %0d bad, burst link %0d bad, %0d cycles",
               STAGES, MODE, LANES - bad, ITEMS, bad, burst_bad, cyc);
    else
      $display("CREDIT_LINK STAGES=%0d MODE=%0d: %0d fault(s) injected, burst link %0d bad, %0d cycles",
               STAGES, MODE, injected, burst_bad, cyc);
    if (MODE == 0) $display("RESULT: %s", (bad == 0 && burst_bad == 0 && burst_done) ? "PASSED" : "FAILED");
    else $display("RESULT: %s", (injected > 0 && burst_bad == 0 && burst_done) ? "PASSED" : "FAILED");
    $finish;
  end
endmodule
