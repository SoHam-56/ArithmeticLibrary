`timescale 1ns / 100ps

module divide_32 (
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

    wire [23:0] Temp_Mantissa;

    reg [22:0] intermediateMan;
    reg [7:0] intermediateExp;
    reg intermediateSign;

    localparam bias = 7'b1111111; // 127
    localparam shiftStages = 24;  // Adjusted for 24-bit division
    reg valid_stage [0:shiftStages+1];

    // Divide by zero and done flags from divider
    wire dbz, div_done;

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
                A_Exponent <= A[30:23];
                B_Mantissa <= {1'b1, B[22:0]};
                B_Exponent <= B[30:23];
            end
        end
    end

    // Unsigned Divider Module
    divu #(
        .WIDTH(24),     // Mantissa width
        .FBITS(23)
    ) divu_mantissa (
        .clk(clk_i), 
        .rst(~rstn_i), 
        .start(valid_stage[0]), 
        .busy(), 
        .done(div_done), 
        .valid(), 
        .dbz(dbz), 
        .ovf(), 
        .a(A_Mantissa), 
        .b(B_Mantissa), 
        .val(Temp_Mantissa)
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

    // Exponent subtraction stages (instead of addition for division)
    reg [2:0] lowest_diff, second_diff, third_diff;
    reg [4:0] final_diff;

    always @(posedge clk_i) begin
        if (capture_valid) begin
            lowest_diff <= A_Exponent_reg[1:0] - B_Exponent_reg[1:0];
        end
    end

    always @(posedge clk_i) begin
        if (lowest_valid) begin
            second_diff <= A_Exponent_reg[3:2] - B_Exponent_reg[3:2] - lowest_diff[2];
        end
    end

    always @(posedge clk_i) begin
        if (second_valid) begin
            third_diff <= A_Exponent_reg[5:4] - B_Exponent_reg[5:4] - second_diff[2];
        end
    end

    always @(posedge clk_i) begin
        if (third_valid) begin
            final_diff <= A_Exponent_reg[7:6] - B_Exponent_reg[7:6] - third_diff[2];
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
            Temp_Exponent <= {final_diff[3:0], third_diff[1:0], second_diff[1:0], lowest_diff[1:0]} + bias;
        end
    end

    // Pipeline for valid signals and other stages
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

    // Final result assembly
    always @(posedge clk_i) begin
        if (div_done) begin
            if (dbz) begin
                intermediateSign <= 'b0;
                intermediateExp <= 'b0;
                intermediateMan <= 'b0;
            end else begin
                intermediateSign <= pipe_sign[shiftStages];
                intermediateExp <= Temp_Mantissa[23] ? pipe_Exponent[shiftStages] : pipe_Exponent[shiftStages] - 1'b1;
                intermediateMan <= Temp_Mantissa[23] ? Temp_Mantissa[22:0] : Temp_Mantissa[22:0] << 1;
            end
        end
    end

    // Output assignments
    reg [2:0] done_shift_reg;

    always @(posedge clk_i or negedge rstn_i) begin
        if (~rstn_i) begin
            done_shift_reg <= 3'b000;
        end else begin
            done_shift_reg <= {done_shift_reg[1:0], div_done};
        end
    end

    // Output assignments
    assign Result[31] = intermediateSign;
    assign Result[30:23] = intermediateExp;
    assign Result[22:0] = intermediateMan;
    assign done_o = done_shift_reg[2];

endmodule
