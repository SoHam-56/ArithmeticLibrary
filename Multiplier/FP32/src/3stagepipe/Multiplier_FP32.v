`timescale 1ns / 1ps

module OG_multiply_32 (
    input wire clk_i,
    input wire rstn_i,
    input wire valid_i,        // Input valid signal
    input wire [31:0] A,
    input wire [31:0] B,
    output wire [31:0] Result,
    output wire done_o         // Done signal
);
    reg [23:0] A_Mantissa, B_Mantissa;
    reg [7:0] A_Exponent, B_Exponent;

    reg sign, sign_A, sign_B;
    reg [7:0] Temp_Exponent;

    reg sign1, sign2, sign3;
    reg [7:0] Temp_Exponent1, Temp_Exponent2, Temp_Exponent3;

    wire [47:0] Temp_Mantissa;

    reg [22:0] intermediateMan, ManChoice1, ManChoice2;
    reg [7:0] intermediateExp, ExpChoice1, ExpChoice2;
    reg intermediateSign, signChoice, choice;

    // Valid signal pipeline registers
    reg valid_stage1, valid_stage2, valid_stage3;
    reg valid_stage4, valid_stage5, valid_stage6, valid_stage7;

    localparam bias = 7'b1111111; // 127

    // Stage 1: Input Registration
    always @ (posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            sign_A <= 'b0;
            sign_B <= 'b0;
            A_Mantissa <= 'b0;
            A_Exponent <= 'b0;
            B_Mantissa <= 'b0;
            B_Exponent <= 'b0;
            valid_stage1 <= 1'b0;
        end else if (valid_i) begin
            if ((~|A[30:0]) | (~|B[30:0])) begin
                sign_A <= 'b0;
                sign_B <= 'b0;
                A_Mantissa <= 'b0;
                A_Exponent <= 'b0;
                B_Mantissa <= 'b0;
                B_Exponent <= 'b0;
            end else begin
                sign_A <= A[31];
                sign_B <= B[31];
                A_Mantissa <= {1'b1, A[22:0]};
                A_Exponent <= A[30:23] - bias;
                B_Mantissa <= {1'b1, B[22:0]};
                B_Exponent <= B[30:23];
            end
            valid_stage1 <= 1'b1;
        end else begin
            valid_stage1 <= 1'b0;
        end
    end

    OG_karatsuba #(24) karatsuba (
        .clk_i(clk_i),
        .rstn_i(rstn_i),
        .multiplicand(A_Mantissa),
        .multiplier(B_Mantissa),
        .product(Temp_Mantissa)
    );

    // Stage 2: Sign and Exponent Calculation
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            sign <= 'b0;
            Temp_Exponent <= 'b0;
            valid_stage2 <= 1'b0;
        end else if (valid_stage1) begin
            sign <= sign_A ^ sign_B;
            Temp_Exponent <= A_Exponent + B_Exponent;
            valid_stage2 <= 1'b1;
        end else begin
            valid_stage2 <= 1'b0;
        end
    end

    // Stage 3: Pipeline I
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            sign1 <= 1'b0;
            Temp_Exponent1 <= 'b0;
            valid_stage3 <= 1'b0;
        end else if (valid_stage2) begin
            sign1 <= sign;
            Temp_Exponent1 <= Temp_Exponent;
            valid_stage3 <= 1'b1;
        end else begin
            valid_stage3 <= 1'b0;
        end
    end

    // Stage 4: Pipeline II
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            sign2 <= 1'b0;
            Temp_Exponent2 <= 'b0;
            valid_stage4 <= 1'b0;
        end else if (valid_stage3) begin
            sign2 <= sign1;
            Temp_Exponent2 <= Temp_Exponent1;
            valid_stage4 <= 1'b1;
        end else begin
            valid_stage4 <= 1'b0;
        end
    end
    
    // Stage 5: Pipeline III
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            sign3 <= 1'b0;
            Temp_Exponent3 <= 'b0;
            valid_stage5 <= 1'b0;
        end else if (valid_stage4) begin
            Temp_Exponent3 <= Temp_Exponent2;
            sign3 <= sign2;
            valid_stage5 <= 1'b1;
        end else begin
            valid_stage5 <= 1'b0;
        end
    end

    // Stage 6: Choice Calculation
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            choice <= 'b0;
            signChoice <= 'b0;
            ExpChoice1 <= 'b0;
            ExpChoice2 <= 'b0;
            ManChoice1 <= 'b0;
            ManChoice2 <= 'b0;
            valid_stage6 <= 1'b0;
        end else if (valid_stage5) begin
            choice <= Temp_Mantissa[47];
            signChoice <= sign3;
            ExpChoice1 <= Temp_Exponent3 + 1'b1;
            ExpChoice2 <= Temp_Exponent3;
            ManChoice1 <= Temp_Mantissa[46:24];
            ManChoice2 <= Temp_Mantissa[45:23];
            valid_stage6 <= 1'b1;
        end else begin
            valid_stage6 <= 1'b0;
        end
    end

    // Stage 7: Final Result Assembly
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            intermediateSign <= 'b0;
            intermediateExp <= 'b0;
            intermediateMan <= 'b0;
            valid_stage7 <= 1'b0;
        end else if (valid_stage6) begin
            intermediateSign <= signChoice;
            intermediateExp <= choice ? ExpChoice1 : ExpChoice2;
            intermediateMan <= choice ? ManChoice1 : ManChoice2;
            valid_stage7 <= 1'b1;
        end else begin
            valid_stage7 <= 1'b0;
        end
    end

    // Output assignments
    assign Result[31] = intermediateSign;
    assign Result[30:23] = intermediateExp;
    assign Result[22:0] = intermediateMan;
    assign done_o = valid_stage7;
endmodule
