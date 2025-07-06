module cntlz8(
  input wire [7:0] in,
  output reg [3:0] o
);

  always @(in) begin
    casez (in)
      8'b1???????: o = 0;
      8'b01??????: o = 1;
      8'b001?????: o = 2;
      8'b0001????: o = 3;
      8'b00001???: o = 4;
      8'b000001??: o = 5;
      8'b0000001?: o = 6;
      8'b00000001: o = 7;
      default: o = 8;
    endcase
  end

endmodule

module cntlz24(
  input [23:0] i,
  output [4:0] o
);

  wire [3:0] cnt1, cnt2, cnt3;

  cntlz8 u1 (i[7: 0],cnt1);
  cntlz8 u2 (i[15: 8],cnt2);
  cntlz8 u3 (i[23:16],cnt3);

  assign o =
    !cnt3[3] ? {1'b0, cnt3} :
    !cnt2[3] ? {1'b0, cnt2} + 4'b1000 :
      {1'b0, cnt1} + 5'b10000;

endmodule
