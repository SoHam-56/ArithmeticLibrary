#include <cstdint>
#include <svdpi.h>

extern "C" {
#include "softfloat.h"
}

// -------------------------------------------------------------------------
// Helper: FTZ (Flush-to-Zero) Logic
// -------------------------------------------------------------------------
// Detects Denormals (Exp=0, Mantissa!=0) and forces them to +/- Zero.
inline uint32_t flush_denormal_to_zero(uint32_t v) {
  // Check if Exponent (bits 30:23) is 0 AND Mantissa (bits 22:0) is NOT 0
  if (((v & 0x7F800000) == 0) && ((v & 0x007FFFFF) != 0)) {
    // Keep Sign bit (31), Force rest to 0
    return (v & 0x80000000);
  }
  return v;
}

extern "C" {

void dpi_init_adder() {
  softfloat_roundingMode = softfloat_round_near_even;
  softfloat_detectTininess = softfloat_tininess_beforeRounding;
}

int c_fp32_add(int a_in, int b_in, int *flags) {
  float32_t fa, fb, fres;
  uint32_t ua = (uint32_t)a_in;
  uint32_t ub = (uint32_t)b_in;

  // 1. Hardware Behavior: Input Flush
  ua = flush_denormal_to_zero(ua);
  ub = flush_denormal_to_zero(ub);

  fa.v = ua;
  fb.v = ub;

  // Reset SoftFloat Global Flags
  softfloat_exceptionFlags = 0;

  // 2. Math Core
  fres = f32_add(fa, fb);

  // 3. Hardware Behavior: Output Flush
  // If the result of the add is a denormal, the HW flushes it to zero.
  // Note: We check the SoftFloat result *before* returning.
  if (flush_denormal_to_zero(fres.v) != fres.v) {
    fres.v = flush_denormal_to_zero(fres.v);

    // OPTIONAL: Standard HW usually sets the Underflow flag when flushing.
    // SoftFloat might have already set it, but we ensure it is set here.
    softfloat_exceptionFlags |= softfloat_flag_underflow;
    softfloat_exceptionFlags |= softfloat_flag_inexact;
  }

  // Capture Flags for SV
  *flags = (int)softfloat_exceptionFlags;

  return (int)fres.v;
}
}
