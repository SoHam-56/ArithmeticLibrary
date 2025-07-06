`timescale 1ns / 1ps

module TB_Karatsuba;

  localparam N = 16;
  localparam TEST_CASES = 13;
  reg clk, rst;
  reg [N-1:0] multiplicand, multiplier;
  wire [(2*N)-1:0] product;

  karatsuba #(N) dut (
    .clk_i(clk),
    .rstn_i(rst),
    .multiplicand(multiplicand),
    .multiplier(multiplier),
    .product(product)
  );

  always #5 clk = ~clk;

  reg [N-1:0] multiplicand_values [0:TEST_CASES-1] = {
    16'h0000,   // All zeros (first test case)
    16'hFFFF,   // All ones (second test case)
    16'h921e, 16'hb8ef, 16'hd73f,
    16'hb092, 16'hd732, 16'hb8ef, 16'hd00d,
    16'h8888, 16'haaaa, 16'h8000, 16'hfffa
  };

  reg [N-1:0] multiplier_values [0:TEST_CASES-1] = {
    16'h0000,   // All zeros (first test case)
    16'hFFFF,   // All ones (second test case)
    16'hb8ef, 16'h921e, 16'h8c8b,
    16'h9a70, 16'hf5ba, 16'h901f, 16'he8a9,
    16'hea32, 16'hf3b3, 16'h988d, 16'haaff
  };

  reg [(2*N)-1:0] expected_product;

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    multiplicand = 0;
    multiplier = 0;
    #10 rst = 1'b0;
    #10 rst = 1'b1;
    for (int i = 0; i < TEST_CASES; i = i + 1) begin
      @(posedge clk);
      multiplicand = multiplicand_values[i];
      multiplier = multiplier_values[i];
      expected_product = multiplicand * multiplier;
      @(posedge clk);
    end
    #100 $finish;
  end

endmodule
