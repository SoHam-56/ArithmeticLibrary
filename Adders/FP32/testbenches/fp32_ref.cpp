#include <cstring>
#include <svdpi.h>

// Helper: Check if number is Denormal (Exp=0, Mantissa!=0)
inline bool is_denormal(float f) {
  int i;
  std::memcpy(&i, &f, sizeof(float));
  // Exponent is bits [30:23].
  return ((i & 0x7F800000) == 0) && ((i & 0x007FFFFF) != 0);
}

// Helper: Flush denormals to pure zero (preserving sign)
inline float flush_to_zero(float f) {
  if (is_denormal(f)) {
    int i;
    std::memcpy(&i, &f, sizeof(float));
    // Keep sign bit (31), clear rest (30:0)
    int result = (i & 0x80000000);
    float f_res;
    std::memcpy(&f_res, &result, sizeof(float));
    return f_res;
  }
  return f;
}

extern "C" int c_fp32_add(int a_in, int b_in) {
  float fa, fb;
  std::memcpy(&fa, &a_in, sizeof(float));
  std::memcpy(&fb, &b_in, sizeof(float));

  // 1. Hardware Behavior: Input Flush
  // Your DUT forces Mantissa to 0 if Exponent is 0.
  fa = flush_to_zero(fa);
  fb = flush_to_zero(fb);

  // 2. Math
  float result = fa + fb;

  // 3. Hardware Behavior: Output Flush
  // Your DUT checks "norm_exp <= 0" and flushes result.
  result = flush_to_zero(result);

  int res_bits;
  std::memcpy(&res_bits, &result, sizeof(float));
  return res_bits;
}
