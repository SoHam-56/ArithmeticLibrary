#include <cstdint>
#include <cstdlib>
#include <ctime>
#include <fstream>
#include <iomanip>
#include <iostream>

extern "C" {
#include "softfloat.h"
}

// This mimics the hardware behavior: If input is denormal, treat as 0.
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

  // Round to Nearest Even, Detect Tininess Before Rounding
  softfloat_roundingMode = softfloat_round_near_even;
  softfloat_detectTininess = softfloat_tininess_beforeRounding;

  // std::srand(std::time(0));
  std::srand(42); // To generate fixed test vectors for git checkin

  std::cout << "Generating 10,000 vectors with DAZ/FTZ logic..." << std::endl;

  for (int i = 0; i < 10000; i++) {
    uint32_t a_raw, b_raw;
    uint32_t a_daz, b_daz;

    // [Phase 1] Hardcoded Corner Cases
    if (i == 0) { // 0 * 1
      a_raw = 0x00000000;
      b_raw = 0x3F800000;
    } else if (i == 1) { // Inf * 1
      a_raw = 0x7F800000;
      b_raw = 0x3F800000;
    } else if (i == 2) { // NaN * 1
      a_raw = 0x7FC00000;
      b_raw = 0x3F800000;
    } else if (i == 3) { // Max Normal * Max Normal (Overflow)
      a_raw = 0x7F7FFFFF;
      b_raw = 0x7F7FFFFF;
    } else if (i == 4) { // Min Normal * Min Normal (Underflow)
      a_raw = 0x00800000;
      b_raw = 0x00800000;
    } else if (i == 5) { // Denormal * Normal (Should trigger DAZ)
      a_raw = 0x00400000;
      b_raw = 0x3F800000;
    } else {
      // [Phase 2] Random Vectors (Full 32-bit range)
      uint32_t r1 = std::rand() ^ (std::rand() << 16);
      uint32_t r2 = std::rand() ^ (std::rand() << 16);
      a_raw = r1;
      b_raw = r2;
    }

    // Apply Hardware Constraints (DAZ)
    a_daz = apply_daz(a_raw);
    b_daz = apply_daz(b_raw);

    // Calculate Golden Result
    float32_t a, b, res;
    a.v = a_daz;
    b.v = b_daz;

    softfloat_exceptionFlags = 0;
    res = f32_mul(a, b);

    int flags = (int)softfloat_exceptionFlags;

    // --- Post-Processing: Flush-to-Zero (FTZ) ---
    // If SoftFloat returns a Denormal result (Exp=0, Mant!=0),
    // Note: SoftFloat sets the Underflow flag, which is correct.
    // Here I zero out the result bits.
    uint32_t res_exp = (res.v >> 23) & 0xFF;
    uint32_t res_man = res.v & 0x007FFFFF;

    if (res_exp == 0 && res_man != 0) {
      // Force Result to Zero (keep sign)
      res.v = (res.v & 0x80000000);
    }

    // --- Write to File ---
    // Write the RAW inputs (so the DUT sees the denormals and triggers its
    // DAZ logic) Check happens against the DAZ/FTZ result.
    outfile << std::hex << std::setfill('0') << std::setw(8)
            << a_raw                 // Input A (Raw)
            << std::setw(8) << b_raw // Input B (Raw)
            << std::setw(8) << res.v // Expected Result (FTZ'd)
            << std::setw(2) << flags // Flags
            << std::endl;
  }

  outfile.close();
  std::cout << "Done! 'vectors.mem' created." << std::endl;
  return 0;
}
