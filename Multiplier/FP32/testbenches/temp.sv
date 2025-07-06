`timescale 1ns / 100ps

module TB_Multi_FP32;
    parameter DATA_WIDTH = 32;
    parameter NUM_TESTS = 11;

    reg clk_n, rst_n, valid_i, valid_ig;
    reg [DATA_WIDTH-1:0] A, B;
    wire [DATA_WIDTH-1:0] Result, Result2;
    wire done_o, done_og;

    // Test vectors
    reg [DATA_WIDTH-1:0] A_values [0:10] = {
        32'b0,
        32'h2317a4db, 32'hb3121ee6, 32'h2b573f9f,
        32'h2f309231, 32'h32d7322b, 32'h3638ef1d,
        32'h39500d01, 32'h3c088889, 32'h3e2aaaab,
        32'h3f800000
    };

    reg [DATA_WIDTH-1:0] B_values [0:10] = {
        32'b0,
        32'b0, 32'h3638ef1d, 32'h298c8b2a,
        32'h2d9a701d, 32'h3175ba87, 32'h35101ffb,
        32'h3868a920, 32'h3b6a3241, 32'h3df3b36a,
        32'h3f988d00
    };

    // Storage for results
    reg [DATA_WIDTH-1:0] results_uut [0:NUM_TESTS-1];
    reg [DATA_WIDTH-1:0] results_og [0:NUM_TESTS-1];
    reg [DATA_WIDTH-1:0] inputs_A [0:NUM_TESTS-1];
    reg [DATA_WIDTH-1:0] inputs_B [0:NUM_TESTS-1];

    // Counters and flags
    reg [3:0] uut_result_count;
    reg [3:0] og_result_count;
    reg all_results_collected;

    // Instantiate modules
    multiply_32 uut1 (
        .clk_i(clk_n),
        .rstn_i(rst_n),
        .valid_i(valid_i),
        .A(A),
        .B(B),
        .Result(Result),
        .done_o(done_o)
    );

    OG_multiply_32 uut2 (
        .clk_i(clk_n),
        .rstn_i(rst_n),
        .valid_i(valid_ig),
        .A(A),
        .B(B),
        .Result(Result2),
        .done_o(done_og)
    );

    // Clock generation
    always #1 clk_n = ~clk_n;

    // Feed data continuously every cycle like your original approach
    initial begin
        // Initialize
        clk_n = 1'b0;
        rst_n = 1'b1;
        valid_i = 1'b0;
        valid_ig = 1'b0;

        $display("Starting testbench...");

        // Reset sequence
        #2 rst_n = 1'b0;
        $display("Time %0t: Reset asserted", $time);
        #4 rst_n = 1'b1;
        $display("Time %0t: Reset deasserted", $time);

        // Wait a few cycles after reset
        #4;

        // Run test vectors - feed data every cycle
        for (int i = 0; i < NUM_TESTS; i = i + 1) begin
            // Apply inputs
            A = A_values[i];
            B = B_values[i];
            inputs_A[i] = A_values[i];
            inputs_B[i] = B_values[i];
            // Assert valid for one cycle
            @(posedge clk_n);
            valid_i = 1'b1;
            valid_ig = 1'b1;
            $display("Time %0t: Feeding test %0d - A=0x%h, B=0x%h", $time, i, A_values[i], B_values[i]);
            @(posedge clk_n);
            valid_i = 1'b0;
            valid_ig = 1'b0;
        end

        $display("Time %0t: Finished feeding all inputs", $time);

        // Wait for all results to be collected
        wait(all_results_collected);
        #10; // Wait a few more cycles to ensure everything is stable

        // Compare all results at the end
        $display("\n=== FINAL RESULTS COMPARISON ===");
        $display("Test# | Input A    | Input B    | UUT Result | OG Result  | Match");
        $display("------|------------|------------|------------|------------|-------");

        for (int i = 0; i < NUM_TESTS; i = i + 1) begin
            if (results_uut[i] == results_og[i]) begin
                $display("%4d  | 0x%08h | 0x%08h | 0x%08h | 0x%08h | PASS",
                         i, inputs_A[i], inputs_B[i], results_uut[i], results_og[i]);
            end else begin
                $display("%4d  | 0x%08h | 0x%08h | 0x%08h | 0x%08h | FAIL",
                         i, inputs_A[i], inputs_B[i], results_uut[i], results_og[i]);
            end
        end

        // Summary
        $display("\n=== TEST SUMMARY ===");
        $display("Total tests: %0d", NUM_TESTS);
        $display("UUT results collected: %0d", uut_result_count);
        $display("OG results collected: %0d", og_result_count);

        // Check for overall pass/fail
        begin
            reg all_pass = 1'b1;
            for (int i = 0; i < NUM_TESTS; i = i + 1) begin
                if (results_uut[i] != results_og[i]) begin
                    all_pass = 1'b0;
                end
            end

            if (all_pass) begin
                $display("*** ALL TESTS PASSED ***");
            end else begin
                $display("*** SOME TESTS FAILED ***");
            end
        end

        $display("Testbench completed at time %0t", $time);
        #10 $finish;
    end

    // Collect results from UUT (Device Under Test)
    always @(posedge clk_n) begin
        if (!rst_n) begin
            uut_result_count <= 0;
        end else if (done_o && uut_result_count < NUM_TESTS) begin
            results_uut[uut_result_count] <= Result;
            $display("Time %0t: UUT Result %0d = 0x%h", $time, uut_result_count, Result);
            uut_result_count <= uut_result_count + 1;
        end
    end

    // Collect results from OG (Reference)
    always @(posedge clk_n) begin
        if (!rst_n) begin
            og_result_count <= 0;
        end else if (done_og && og_result_count < NUM_TESTS) begin
            results_og[og_result_count] <= Result2;
            $display("Time %0t: OG Result %0d = 0x%h", $time, og_result_count, Result2);
            og_result_count <= og_result_count + 1;
        end
    end

    // Check if all results are collected
    always @(posedge clk_n) begin
        all_results_collected <= (uut_result_count == NUM_TESTS) && (og_result_count == NUM_TESTS);
    end



    // Timeout protection
    initial begin
        #5000; // Adjust timeout as needed
        $display("ERROR: Testbench timeout!");
        $finish;
    end

endmodule
