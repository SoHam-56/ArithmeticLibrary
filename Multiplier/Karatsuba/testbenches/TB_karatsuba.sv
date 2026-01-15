`timescale 1ns / 100ps

module TB_karatsuba;

  localparam WIDTH = 16;
  localparam TEST_COUNT = 50;

  logic clk = 0;
  logic rstn;

  logic unsigned_valid_i, unsigned_valid_o;
  logic [WIDTH-1:0] unsigned_multiplicand, unsigned_multiplier;
  logic [(2*WIDTH)-1:0] unsigned_product_dut;
  logic [(2*WIDTH)-1:0] unsigned_queue[$];

  logic signed_valid_i, signed_valid_o;
  logic signed [WIDTH-1:0] signed_multiplicand, signed_multiplier;
  logic signed [(2*WIDTH)-1:0] signed_product_dut;
  logic signed [(2*WIDTH)-1:0] signed_queue[$];

  int unsigned_error_count = 0;
  int unsigned_transaction_count = 0;
  int signed_error_count = 0;
  int signed_transaction_count = 0;

  karatsubaUnsigned #(WIDTH) dut_unsigned (
      .clk_i(clk),
      .rstn_i(rstn),
      .valid_i(unsigned_valid_i),
      .multiplicand_i(unsigned_multiplicand),
      .multiplier_i(unsigned_multiplier),
      .valid_o(unsigned_valid_o),
      .product_o(unsigned_product_dut)
  );

  karatsubaSigned #(WIDTH) dut_signed (
      .clk_i(clk),
      .rstn_i(rstn),
      .valid_i(signed_valid_i),
      .a_i(signed_multiplicand),
      .b_i(signed_multiplier),
      .valid_o(signed_valid_o),
      .product_o(signed_product_dut)
  );

  always #5 clk = ~clk;

  task system_reset();
    rstn = 0;
    unsigned_valid_i = 0;
    unsigned_multiplicand = 0;
    unsigned_multiplier = 0;
    signed_valid_i = 0;
    signed_multiplicand = 0;
    signed_multiplier = 0;

    repeat (5) @(posedge clk);
    rstn = 1;
    repeat (2) @(posedge clk);
  endtask

  task drive_unsigned_transaction(input logic [WIDTH-1:0] a, input logic [WIDTH-1:0] b);
    unsigned_valid_i <= 1;
    unsigned_multiplicand <= a;
    unsigned_multiplier <= b;
    unsigned_queue.push_back((2 * WIDTH)'(a) * (2 * WIDTH)'(b));
  endtask

  task drive_signed_transaction(input logic signed [WIDTH-1:0] a, input logic signed [WIDTH-1:0] b);
    signed_valid_i <= 1;
    signed_multiplicand <= a;
    signed_multiplier <= b;
    signed_queue.push_back((2 * WIDTH)'(a) * (2 * WIDTH)'(b));
  endtask

  always @(posedge clk) begin
    if (rstn && unsigned_valid_o) begin
      logic [(2*WIDTH)-1:0] expected_val = unsigned_queue.pop_front();
      unsigned_transaction_count++;

      if (unsigned_product_dut !== expected_val) begin
        $error("Unsigned Mismatch: Expected %h, Got %h", expected_val, unsigned_product_dut);
        unsigned_error_count++;
      end
    end
  end

  always @(posedge clk) begin
    if (rstn && signed_valid_o) begin
      logic signed [(2*WIDTH)-1:0] expected_val = signed_queue.pop_front();
      signed_transaction_count++;

      if (signed_product_dut !== expected_val) begin
        $error("Signed Mismatch: Expected %d, Got %d", expected_val, signed_product_dut);
        signed_error_count++;
      end
    end
  end

  logic [WIDTH-1:0] test_patterns[] = '{16'h0000, 16'hFFFF, 16'h1234, 16'h8000, 16'h7FFF};

  initial begin

    system_reset();

    foreach (test_patterns[i]) begin
      drive_unsigned_transaction(test_patterns[i], test_patterns[i]);
      drive_signed_transaction(test_patterns[i], test_patterns[i]);
      @(posedge clk);
    end

    unsigned_valid_i <= 0;
    signed_valid_i   <= 0;
    @(posedge clk);

    repeat (TEST_COUNT) begin
      drive_unsigned_transaction($urandom, $urandom);
      drive_signed_transaction($urandom, $urandom);
      @(posedge clk);
    end

    unsigned_valid_i <= 0;
    signed_valid_i   <= 0;

    wait (unsigned_queue.size() == 0 && signed_queue.size() == 0);
    repeat (10) @(posedge clk);

    if (unsigned_error_count == 0 && signed_error_count == 0)
      $display(
          "\nPASS: Unsigned(%0d) and Signed(%0d) vectors passed.\n",
          unsigned_transaction_count,
          signed_transaction_count
      );
    else
      $display(
          "\nFAIL: Errors found. Unsigned: %0d, Signed: %0d\n",
          unsigned_error_count,
          signed_error_count
      );

    $finish;
  end

  initial begin
    $dumpfile("TB_karatsuba.vcd");
    $dumpvars(0, TB_karatsuba);
  end

endmodule
