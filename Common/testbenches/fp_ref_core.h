// SoftFloat reference for floats with an 8-bit exponent: exact widening to f32, the op rounded to odd at 24 bits, then nearest-even
// at MAN_W bits, which is correctly rounded (MAN_W = 23 is plain f32 nearest-even). The units' policy on top: subnormal inputs read
// as zero, results tiny before rounding flush to a signed zero with underflow, NaN is canonical; the flags are the round-to-odd
// f32 op's, which are round-toward-zero's, the units' rounding direction.
#pragma once
#include <cstdint>
extern "C" {
#include "softfloat.h"
}

static inline uint32_t fpref_widen(uint32_t x, int man_w) {
  uint32_t f = x << (23 - man_w);
  if (((f >> 23) & 0xFFu) == 0) f &= 0x80000000u;  // subnormal reads as zero
  return f;
}

static inline uint32_t fpref_narrow(uint32_t f, int man_w, int *flags) {
  const uint32_t sh = 23 - man_w, sign = f & 0x80000000u, mag = f & 0x7FFFFFFFu;
  if ((mag >> 23) == 0xFFu) return (mag & 0x7FFFFFu) ? (0x7FC00000u >> sh) : ((sign | 0x7F800000u) >> sh);
  if ((*flags & softfloat_flag_underflow) || ((mag >> 23) == 0 && mag != 0)) {  // tiny: flushed
    *flags |= softfloat_flag_underflow | softfloat_flag_inexact;
    return sign >> sh;
  }
  if (sh == 0) return f;
  uint32_t r = (mag + (1u << (sh - 1)) - 1u + ((mag >> sh) & 1u)) >> sh;
  if (mag & ((1u << sh) - 1u)) *flags |= softfloat_flag_inexact;
  if ((r >> man_w) >= 0xFFu) {  // nearest rounds up to infinity; truncation does not, so no overflow flag
    *flags |= softfloat_flag_inexact;
    r = 0xFFu << man_w;
  }
  return (sign >> sh) | r;
}

// op 0 multiplies, op 1 adds; returns the expected result bits and sets *flags.
static inline uint32_t fpref_op(int op, uint32_t a, uint32_t b, int man_w, int *flags) {
  float32_t fa, fb, fr;
  fa.v = fpref_widen(a, man_w);
  fb.v = fpref_widen(b, man_w);
  softfloat_roundingMode = (man_w == 23) ? softfloat_round_near_even : softfloat_round_odd;
  softfloat_detectTininess = softfloat_tininess_beforeRounding;
  softfloat_exceptionFlags = 0;
  fr = op ? f32_add(fa, fb) : f32_mul(fa, fb);
  *flags = softfloat_exceptionFlags;
  return fpref_narrow(fr.v, man_w, flags);
}
