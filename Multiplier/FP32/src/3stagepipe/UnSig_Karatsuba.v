`timescale 1ns / 1ps

module OG_karatsuba #(
    parameter WIDTH = 24
) (
    input clk_i,
    input rstn_i,
    input [WIDTH-1:0] multiplicand,
    input [WIDTH-1:0] multiplier,
    output [(2*WIDTH)-1:0] product
);
    localparam HALF_WIDTH = WIDTH / 2;
    localparam MID_WIDTH = HALF_WIDTH + 1;

    wire [WIDTH-1:0] P_high, P_low;
    wire [WIDTH+1:0] P_middle;

    wire [MID_WIDTH-1:0] temp1, temp2;
    wire [WIDTH:0] temp3;

    wire [HALF_WIDTH-1:0] A_high = multiplicand[WIDTH-1:HALF_WIDTH];
    wire [HALF_WIDTH-1:0] A_low  = multiplicand[HALF_WIDTH-1:0];
    wire [HALF_WIDTH-1:0] B_high = multiplier[WIDTH-1:HALF_WIDTH];
    wire [HALF_WIDTH-1:0] B_low  = multiplier[HALF_WIDTH-1:0];

    // Instantiate Booth multipliers
    R4Booth #(HALF_WIDTH) booth_mult1 (
        .clk_i(clk_i),
        .rstn_i(rstn_i),
        .multiplicand(A_low),
        .multiplier(B_low),
        .product(P_low)
    );

    R4Booth #(HALF_WIDTH) booth_mult2 (
        .clk_i(clk_i),
        .rstn_i(rstn_i),
        .multiplicand(A_high),
        .multiplier(B_high),
        .product(P_high)
    );

    R4Booth #(MID_WIDTH) booth_mult3 (
        .clk_i(clk_i),
        .rstn_i(rstn_i),
        .multiplicand(temp1),
        .multiplier(temp2),
        .product(P_middle)
    );

    assign temp1 = A_high + A_low;
    assign temp2 = B_high + B_low;
    assign temp3 = P_middle - P_high - P_low;

    assign product = (P_high << WIDTH) + (temp3 << HALF_WIDTH) + P_low;

endmodule

