#include <cstdint>
#include <svdpi.h>

extern "C" {
#include "softfloat.h"
}

extern "C" {

void dpi_init_softfloat() {
  softfloat_roundingMode = softfloat_round_near_even;
  softfloat_detectTininess = softfloat_tininess_beforeRounding;
}

int c_fp32_multiply(int a, int b, int *flags) {
  float32_t fa, fb, fres;

  // Bit-cast SV int to SoftFloat struct
  fa.v = (uint32_t)a;
  fb.v = (uint32_t)b;

  // Reset flags
  softfloat_exceptionFlags = 0;

  // Multiply
  fres = f32_mul(fa, fb);

  // Capture flags (Overflow, Underflow, etc.)
  *flags = (int)softfloat_exceptionFlags;

  return (int)fres.v;
}
}
