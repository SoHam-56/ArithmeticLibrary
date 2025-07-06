`timescale 1ns / 100ps

module multiply_32 (
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

    wire [47:0] Temp_Mantissa;

    reg [22:0] intermediateMan, ManChoice1, ManChoice2;
    reg [7:0] intermediateExp, ExpChoice1, ExpChoice2;
    reg intermediateSign, signChoice, choice;

    localparam bias = 7'b1111111; // 127
    localparam shiftStages = 5;
    reg valid_stage [0:shiftStages+3];

    // Stage 1: Control path - valid signal
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            valid_stage[0] <= 1'b0;
        end else begin
            valid_stage[0] <= valid_i;
        end
    end

    // Stage 1: Data path - input registration
    always @(posedge clk_i) begin
        if (valid_i) begin
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
        end
    end

    karatsuba #(24) karatsuba (
        .clk_i(clk_i),
        .rstn_i(rstn_i),
        .multiplicand(A_Mantissa),
        .multiplier(B_Mantissa),
        .product(Temp_Mantissa)
    );

    // Stage 2: Control path - capture valid
    reg capture_valid;
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            capture_valid <= 1'b0;
        end else begin
            capture_valid <= valid_stage[0];
        end
    end

    // Stage 2: Data path - sign and exponent registration
    reg [7:0] A_Exponent_reg, B_Exponent_reg;
    always @(posedge clk_i) begin
        if (valid_stage[0]) begin
            sign <= sign_A ^ sign_B;
            A_Exponent_reg <= A_Exponent;
            B_Exponent_reg <= B_Exponent;
        end
    end

    // Control path - valid signals for addition stages
    reg lowest_valid, second_valid, third_valid, final_valid;
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            lowest_valid <= 1'b0;
            second_valid <= 1'b0;
            third_valid <= 1'b0;
            final_valid <= 1'b0;
        end else begin
            lowest_valid <= capture_valid;
            second_valid <= lowest_valid;
            third_valid <= second_valid;
            final_valid <= third_valid;
        end
    end

    // Data path - exponent addition stages
    reg [2:0] lowest_sum, second_sum, third_sum;
    reg [4:0] final_sum;

    always @(posedge clk_i) begin
        if (capture_valid) begin
            lowest_sum <= A_Exponent_reg[1:0] + B_Exponent_reg[1:0];
        end
    end

    always @(posedge clk_i) begin
        if (lowest_valid) begin
            second_sum <= A_Exponent_reg[3:2] + B_Exponent_reg[3:2] + lowest_sum[2];
        end
    end

    always @(posedge clk_i) begin
        if (second_valid) begin
            third_sum <= A_Exponent_reg[5:4] + B_Exponent_reg[5:4] + second_sum[2];
        end
    end

    always @(posedge clk_i) begin
        if (third_valid) begin
            final_sum <= A_Exponent_reg[7:6] + B_Exponent_reg[7:6] + third_sum[2];
        end
    end

    // Control path - pipeline valid signals
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            valid_stage[1] <= 1'b0;
        end else begin
            valid_stage[1] <= final_valid;
        end
    end

    // Data path - exponent assembly
    always @(posedge clk_i) begin
        if (final_valid) begin
            Temp_Exponent <= {final_sum[3:0], third_sum[1:0], second_sum[1:0], lowest_sum[1:0]};
        end
    end

    // Control path - pipeline valid signals
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            for (int i = 1; i <= shiftStages; i = i + 1) begin
                valid_stage[i + 1] <= 1'b0;
            end
        end else begin
            for (int i = 1; i <= shiftStages; i = i + 1) begin
                valid_stage[i + 1] <= valid_stage[i];
            end
        end
    end

    // Data path - sign and exponent pipeline registers
    reg pipe_sign [1:shiftStages];
    reg [7:0] pipe_Exponent [1:shiftStages];

    always @(posedge clk_i) begin
        for (int i = 1; i <= shiftStages; i = i + 1) begin
            if (valid_stage[i]) begin
                pipe_sign[i] <= (i == 1) ? sign : pipe_sign[i - 1];
                pipe_Exponent[i] <= (i == 1) ? Temp_Exponent : pipe_Exponent[i - 1];
            end
        end
    end

    // Control path - final stages valid signals
    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            valid_stage[7] <= 1'b0;
            valid_stage[8] <= 1'b0;
        end else begin
            valid_stage[7] <= valid_stage[6];
            valid_stage[8] <= valid_stage[7];
        end
    end

    // Data path - choice calculation
    always @(posedge clk_i) begin
        if (valid_stage[6]) begin
            choice <= Temp_Mantissa[47];
            signChoice <= pipe_sign[shiftStages];
            ExpChoice1 <= pipe_Exponent[shiftStages] + 1'b1;
            ExpChoice2 <= pipe_Exponent[shiftStages];
            ManChoice1 <= Temp_Mantissa[46:24];
            ManChoice2 <= Temp_Mantissa[45:23];
        end
    end

    // Data path - final result assembly
    always @(posedge clk_i) begin
        if (valid_stage[7]) begin
            intermediateSign <= signChoice;
            intermediateExp <= choice ? ExpChoice1 : ExpChoice2;
            intermediateMan <= choice ? ManChoice1 : ManChoice2;
        end
    end

    // Output assignments
    assign Result[31] = intermediateSign;
    assign Result[30:23] = intermediateExp;
    assign Result[22:0] = intermediateMan;
    assign done_o = valid_stage[8];

endmodule
