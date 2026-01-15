`timescale 1ns / 100ps

module cntlz28 (
    input  logic [27:0] i,
    output logic [ 4:0] o
);
  logic [3:0] c_hi, c_mid, c_lo, c_bot;

  // Top 8 bits [27:20]
  cntlz8 u1 (
      i[27:20],
      c_hi
  );
  // Next 8 bits [19:12]
  cntlz8 u2 (
      i[19:12],
      c_mid
  );
  // Next 8 bits [11:4]
  cntlz8 u3 (
      i[11:4],
      c_lo
  );
  // Bottom 4 bits [3:0] (padded with 0s for the 8-bit module)
  cntlz8 u4 (
      {i[3:0], 4'b0},
      c_bot
  );

  always_comb begin
    if (i[27:20] != 0) o = {1'b0, c_hi};
    else if (i[19:12] != 0) o = {1'b0, c_mid} + 5'd8;
    else if (i[11:4] != 0) o = {1'b0, c_lo} + 5'd16;
    else if (i[3:0] != 0) o = {1'b0, c_bot} + 5'd24;
    else o = 5'd28;  // All Zeros
  end
endmodule

module cntlz8 (
    input  logic [7:0] in,
    output logic [3:0] o
);
  always_comb begin
    casez (in)
      8'b1???????: o = 0;
      8'b01??????: o = 1;
      8'b001?????: o = 2;
      8'b0001????: o = 3;
      8'b00001???: o = 4;
      8'b000001??: o = 5;
      8'b0000001?: o = 6;
      8'b00000001: o = 7;
      default:     o = 8;
    endcase
  end
endmodule

