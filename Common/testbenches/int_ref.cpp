// DPI wrappers of int_ref_core.h for the integer-unit testbenches.
#include <svdpi.h>
#include "int_ref_core.h"

extern "C" int c_int_mul(int a, int b, int w) { return (int)iref_mul(a, b, w); }

extern "C" int c_int_add(int a, int b, int w) { return (int)iref_add(a, b, w); }

extern "C" int c_fx_mac(int a, int x, int c, int w, int frac) { return (int)iref_fx_mac(a, x, c, w, frac); }

// m, m1 and m2 arrive as int and are read back as their unsigned 32-bit patterns.
extern "C" int c_int8_requantize(int acc, int m, int e, int zp, int lo, int hi) {
  return (int)iref_requantize(acc, (uint32_t)m, e, zp, lo, hi);
}

extern "C" int c_int8_quantized_add(int q1, int q2, int z1, int z2, int m1, int m2, int e, int zo, int lo, int hi) {
  return (int)iref_qadd(q1, q2, z1, z2, (uint32_t)m1, (uint32_t)m2, e, zo, lo, hi);
}
