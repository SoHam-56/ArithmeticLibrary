#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <iostream>

extern "C" {
#include "softfloat.h"
}

// Helper: Hardware behavior - Flush Input Denormals to Zero (DAZ)
uint32_t apply_daz(uint32_t val) {
  uint32_t exp = (val >> 23) & 0xFF;
  uint32_t mant = val & 0x007FFFFF;

  // If Exponent is 0 but Mantissa is non-zero (Denormal), flush to Zero.
  // Preserve the sign bit.
  if (exp == 0 && mant != 0) {
    return (val & 0x80000000);
  }
  return val;
}

int main() {
  std::ofstream outfile("vectors.mem");

  if (!outfile.is_open()) {
    std::cerr << "Error: Could not create vectors.mem" << std::endl;
    return 1;
  }

  // Configure SoftFloat: Round Nearest Even
  softfloat_roundingMode = softfloat_round_near_even;
  softfloat_detectTininess = softfloat_tininess_beforeRounding;

  std::srand(42); // Fixed seed for reproducibility

  std::cout << "Generating 10,000 ADDER vectors with DAZ/FTZ logic..."
            << std::endl;

  for (int i = 0; i < 10000; i++) {
    uint32_t a_raw, b_raw;
    uint32_t a_daz, b_daz;

    // [Phase 1] Hardcoded Corner Cases for Adder
    if (i == 0) { // 0 + 0
      a_raw = 0x00000000;
      b_raw = 0x00000000;
    } else if (i == 1) { // 1.0 + 0
      a_raw = 0x3F800000;
      b_raw = 0x00000000;
    } else if (i == 2) { // Inf + 1.0
      a_raw = 0x7F800000;
      b_raw = 0x3F800000;
    } else if (i == 3) { // +Inf + -Inf (NaN - Invalid Op)
      a_raw = 0x7F800000;
      b_raw = 0xFF800000;
    } else if (i == 4) { // NaN + Normal
      a_raw = 0x7FC00000;
      b_raw = 0x3F800000;
    } else if (i == 5) { // Cancellation: 1.5 - 1.0 = 0.5
      a_raw = 0x3FC00000;
      b_raw = 0xBF800000;
    } else if (i == 6) { // Massive Cancellation: 1.0000001 - 1.0
      a_raw = 0x3F800001;
      b_raw = 0xBF800000;
    } else if (i == 7) { // Denormal + Normal (DAZ Test)
      a_raw = 0x00400000;
      b_raw = 0x3F800000;
    } else {
      // [Phase 2] Random Vectors
      uint32_t r1 = std::rand() ^ (std::rand() << 16);
      uint32_t r2 = std::rand() ^ (std::rand() << 16);
      a_raw = r1;
      b_raw = r2;
    }

    // 1. Hardware Behavior: Input Flush (DAZ)
    a_daz = apply_daz(a_raw);
    b_daz = apply_daz(b_raw);

    // 2. Compute Golden Result
    float32_t a, b, res;
    a.v = a_daz;
    b.v = b_daz;

    softfloat_exceptionFlags = 0;
    res = f32_add(a, b); // <--- ADDITION

    int flags = (int)softfloat_exceptionFlags;

    // 3. Hardware Behavior: Output Flush (FTZ)
    // If result is Denormal, force to Zero.
    uint32_t res_exp = (res.v >> 23) & 0xFF;
    uint32_t res_man = res.v & 0x007FFFFF;

    if (res_exp == 0 && res_man != 0) {
      res.v = (res.v & 0x80000000); // Keep sign, clear mantissa
      // Hardware usually sets Underflow/Inexact here,
      // but SoftFloat likely already set them.
    }

    // 4. Write to File
    // Format: A(32) B(32) Res(32) Flags(8)
    outfile << std::hex << std::setfill('0') << std::setw(8)
            << a_raw                 // Input A (Raw)
            << std::setw(8) << b_raw // Input B (Raw)
            << std::setw(8) << res.v // Expected Result
            << std::setw(2) << flags // Flags
            << std::endl;
  }

  outfile.close();
  std::cout << "Done! 'vectors.mem' created for Adder." << std::endl;
  return 0;
}
