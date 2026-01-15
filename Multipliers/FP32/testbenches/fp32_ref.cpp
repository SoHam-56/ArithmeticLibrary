#include <cstring>
#include <svdpi.h>

// This function forces C++ to use native 32-bit float math
extern "C" int c_fp32_multiply(int a, int b) {
  float fa, fb;

  // Copy bits safely (avoids strict aliasing violations)
  std::memcpy(&fa, &a, sizeof(float));
  std::memcpy(&fb, &b, sizeof(float));

  float result = fa * fb;

  int res_bits;
  std::memcpy(&res_bits, &result, sizeof(float));
  return res_bits;
}
