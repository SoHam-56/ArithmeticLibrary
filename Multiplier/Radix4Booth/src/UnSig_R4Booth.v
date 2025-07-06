`timescale 1ns / 1ps

module R4Booth #(
  parameter N = 24
)(
  input clk_i, input rstn_i,
  input [N-1:0] multiplicand,
  input [N-1:0] multiplier,
  output reg [(2*N)-1:0] product
);

  reg [2*N-1:0] partial_product[0:N/2];
  reg [2*N-1:0] partial_product_hold[0:N/2];

  reg [2:0] mul_mod[0:N/2];
  
  wire [(N % 2 == 0) ? (N+2): (N+1) : 0] _multiplier_; 
  wire [N:0] _multiplicand;

  reg [2*N-1:0] val[0:N/4-1];
  reg [2*N-1:0] val_next[0:N/4-1];
  
  reg [N-1:0] multiplicand_hold;
  reg [N-1:0] multiplier_hold;
  
  reg [2*N-1:0] partial_product_last;
  reg  [(2*N)-1:0] accum;
  
  integer i;

  always @(posedge clk_i or negedge rstn_i) begin
    if (~rstn_i) begin
      multiplicand_hold <= 'b0;
      multiplier_hold <= 'b0;
    end else begin
      multiplicand_hold <= multiplicand;
      multiplier_hold <= multiplier;
    end
  end

  assign _multiplier_ = (N % 2 == 0) ? {1'b0, 1'b0, multiplier_hold, 1'b0} : {1'b0, multiplier_hold, 1'b0};
  assign _multiplicand = {1'b0, multiplicand_hold};
  
  always @(*) begin
    for (i = 0; i < N/2+1; i=i+1)
        mul_mod[i] = _multiplier_[2*i +: 3];
    
    for (i = 0; i < N/2+1; i = i + 1) begin
      case(mul_mod[i])
        3'b000: partial_product[i] = 'b0;
        3'b001: partial_product[i] = _multiplicand;
        3'b010: partial_product[i] = _multiplicand;
        3'b011: partial_product[i] = _multiplicand << 1;
        3'b100: partial_product[i] = ~(_multiplicand << 1) + 1'b1;
        3'b101: partial_product[i] = ~_multiplicand + 1'b1;
        3'b110: partial_product[i] = ~_multiplicand + 1'b1;
        3'b111: partial_product[i] = 'b0;
      endcase
    end
  end
  
  always @(posedge clk_i or negedge rstn_i) begin
    if (~rstn_i)
      for (i = 0; i < N/2 + 1; i = i + 1)
        partial_product_hold[i] <= 'b0;

    else
      for (i = 0; i < N/2 + 1; i = i + 1)
        partial_product_hold[i] <= partial_product[i];
  end

  always @(*) begin
    for (i = 0; i < N/4; i = i + 1) 
      val[i] = partial_product_hold[2*i] + (partial_product_hold[2*i+1] << 2);
  end

  always @(posedge clk_i or negedge rstn_i) begin
    if (~rstn_i)
      for (i = 0; i < N/4; i = i + 1)
        val_next[i] <= 'b0;
    else
      for (i = 0; i < N/4; i = i + 1)
        val_next[i] <= val[i];
  end
  
  always @(posedge clk_i or negedge rstn_i) begin
    if (~rstn_i) 
      partial_product_last <= 'b0;
    else 
      partial_product_last <= (N % 2 == 0) ? (partial_product_hold[N/2] << N) : (partial_product_hold[N/2] << (N-1));
  end

  always @(*) begin
    accum = partial_product_last;
    for (i = 0; i < N/4; i = i + 1) 
      accum = accum + (val_next[i] << (4 * i));
  end

  always @(posedge clk_i or negedge rstn_i) begin
    if (~rstn_i) 
      product <= 'b0;
    else 
      product <= accum;
  end

//  assign product = accum;

endmodule
