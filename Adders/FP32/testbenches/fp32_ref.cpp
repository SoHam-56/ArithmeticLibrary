#include <cstring>
#include <svdpi.h>

// Check for denormal (Exp = 0, Mantissa != 0)
bool is_denormal(float f) {
  int i;
  std::memcpy(&i, &f, sizeof(float));
  // Exponent is bits [30:23]. If 0, and not pure zero, it's denormal.
  return ((i & 0x7F800000) == 0) && ((i & 0x007FFFFF) != 0);
}

// Flush denormals to zero
float flush_to_zero(float f) {
  if (is_denormal(f))
    return 0.0f;
  return f;
}

extern "C" int c_fp32_add(int a_in, int b_in) {
  float fa, fb;
  std::memcpy(&fa, &a_in, sizeof(float));
  std::memcpy(&fb, &b_in, sizeof(float));

  // Hardware Behavior: Flush Inputs?
  // Hardware handles denormal inputs as 0 in Stage 1 logic
  // (hidden_bit = 0 if exp == 0). So we should flush inputs.
  fa = flush_to_zero(fa);
  fb = flush_to_zero(fb);

  // Perform Math
  float result = fa + fb;

  // Hardware Behavior: Flush Output?
  // Hardware explicitly zeroes out underflows.
  result = flush_to_zero(result);

  int res_bits;
  std::memcpy(&res_bits, &result, sizeof(float));
  return res_bits;
}
