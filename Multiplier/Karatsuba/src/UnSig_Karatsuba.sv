`timescale 1ns / 1ps

module karatsuba #(
    parameter WIDTH = 24
) (
    input logic clk_i,
    input logic rstn_i,
    input logic [WIDTH-1:0] multiplicand,
    input logic [WIDTH-1:0] multiplier,
    output logic [(2*WIDTH)-1:0] product
);

    localparam HALF_WIDTH = WIDTH / 2;
    localparam MID_WIDTH = HALF_WIDTH + 1;

    // Stage 1: Split inputs into high and low parts
    logic [HALF_WIDTH-1:0] A_high, A_low, B_high, B_low;
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            A_high <= 0;
            A_low  <= 0;
            B_high <= 0;
            B_low  <= 0;
        end else begin
            A_high <= multiplicand[WIDTH-1:HALF_WIDTH];
            A_low  <= multiplicand[HALF_WIDTH-1:0];
            B_high <= multiplier[WIDTH-1:HALF_WIDTH];
            B_low  <= multiplier[HALF_WIDTH-1:0];
        end
    end

    // Stage 2: Booth multipliers for partial products
    logic [WIDTH-1:0] P_low_raw, P_high_raw;
    logic [WIDTH+1:0] P_middle;

    R4Booth #(HALF_WIDTH) booth_mult1 (
        .clk_i(clk_i),
        .rstn_i(rstn_i),
        .multiplicand(A_low),
        .multiplier(B_low),
        .product(P_low_raw)
    );

    R4Booth #(HALF_WIDTH) booth_mult2 (
        .clk_i(clk_i),
        .rstn_i(rstn_i),
        .multiplicand(A_high),
        .multiplier(B_high),
        .product(P_high_raw)
    );

    logic [MID_WIDTH-1:0] temp1, temp2;
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            temp1 <= 0;
            temp2 <= 0;
        end else begin
            temp1 <= A_high + A_low;
            temp2 <= B_high + B_low;
        end
    end

    R4Booth #(MID_WIDTH) booth_mult3 (
        .clk_i(clk_i),
        .rstn_i(rstn_i),
        .multiplicand(temp1),
        .multiplier(temp2),
        .product(P_middle)
    );

    // Align P_high and P_low with P_middle
    logic [WIDTH-1:0] P_high, P_low;
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            P_high <= 0;
            P_low  <= 0;
        end else begin
            P_high <= P_high_raw;
            P_low  <= P_low_raw;
        end
    end

    // Stage 3: Compute P_middle - P_high
    logic [WIDTH+1:0] temp3_stage1, P_low2;
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            temp3_stage1 <= 0;
            P_low2 <= 'b0;
        end else begin
            temp3_stage1 <= P_middle - P_high;
            P_low2 <= P_low;
        end
    end

    // Stage 4: Compute temp3
    logic [WIDTH:0] temp3;
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            temp3 <= 0;
        end else begin
            temp3 <= temp3_stage1 - P_low2;
        end
    end

    // Stage 5: Compute P_high << WIDTH
    logic [(2*WIDTH)-1:0] P_high_shifted, P_high_shifted1, P_high_shifted2;
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            P_high_shifted <= 0;
            P_high_shifted1 <= 0;
            P_high_shifted2 <= 0;
        end else begin
            P_high_shifted <= P_high << WIDTH;
            P_high_shifted1 <= P_high_shifted;
            P_high_shifted2 <= P_high_shifted1;
        end
    end

    // Stage 6: Compute temp3 << HALF_WIDTH
    logic [(2*WIDTH)-1:0] temp3_shifted;
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            temp3_shifted <= 0;
        end else begin
            temp3_shifted <= temp3 << HALF_WIDTH;
        end
    end

    // Stage 7: Compute partial_product = P_high_shifted + temp3_shifted
    logic [(2*WIDTH)-1:0] partial_product;
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            partial_product <= 0;
        end else begin
            partial_product <= P_high_shifted2 + temp3_shifted;
        end
    end

    // Stage 8: Compute final product = partial_product + P_low
    logic [(2*WIDTH)-1:0] P_low_extended, P_low_extended1, P_low_extended2;
    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            P_low_extended <= 0;
            P_low_extended1 <= 0;
            P_low_extended2 <= 0;
        end else begin
            P_low_extended <= P_low2;
            P_low_extended1 <= P_low_extended;
            P_low_extended2 <= P_low_extended1;
        end
    end

    always_ff @(posedge clk_i or negedge rstn_i) begin
        if (!rstn_i) begin
            product <= 0;
        end else begin
            product <= partial_product + P_low_extended2;
        end
    end
endmodule
