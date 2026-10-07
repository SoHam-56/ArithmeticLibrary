`timescale 1ns / 100ps

// STAGES register stages on a link: put and data forward, credit back; 0 is wires.
/* verilator lint_off UNUSEDSIGNAL */
module credit_reg #(parameter int STAGES = 0, parameter int DATA_W = 32, parameter int CRW = 1) (
    input logic clk_i, rstn_i,
    credit_link_if.consumer up,
    credit_link_if.producer dn
);
/* verilator lint_on UNUSEDSIGNAL */
`ifndef SYNTHESIS  // interface widths are not elaboration constants in Verilator, so they are checked at time 0
  initial
    if ($bits(up.data) != DATA_W || $bits(dn.data) != DATA_W || $bits(up.credit) != CRW || $bits(dn.credit) != CRW)
      $fatal(1, "credit_reg: DATA_W %0d and CRW %0d, but the links have data %0d/%0d and credit %0d/%0d", DATA_W, CRW, $bits(up.data),
             $bits(dn.data), $bits(up.credit), $bits(dn.credit));
`endif
  if (STAGES == 0) begin : g_wire
    assign dn.put = up.put;
    assign dn.data = up.data;
    assign up.credit = dn.credit;
  end else begin : g_regs
    logic              put_q [STAGES];
    logic [DATA_W-1:0] data_q[STAGES];
    logic [CRW-1:0]    cred_q[STAGES];
    always_ff @(posedge clk_i or negedge rstn_i)
      if (!rstn_i) for (int i = 0; i < STAGES; i++) begin put_q[i] <= 1'b0; cred_q[i] <= '0; end
      else begin
        put_q[0] <= up.put; cred_q[0] <= dn.credit;
        for (int i = 1; i < STAGES; i++) begin put_q[i] <= put_q[i-1]; cred_q[i] <= cred_q[i-1]; end
      end
    always_ff @(posedge clk_i) begin  // datapath, not reset (D-8)
      data_q[0] <= up.data;
      for (int i = 1; i < STAGES; i++) data_q[i] <= data_q[i-1];
    end
    assign dn.put = put_q[STAGES-1];
    assign dn.data = data_q[STAGES-1];
    assign up.credit = cred_q[STAGES-1];
  end
endmodule
