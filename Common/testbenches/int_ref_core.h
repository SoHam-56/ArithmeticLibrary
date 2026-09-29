// Reference arithmetic for the integer units, written from the definitions: two's complement, floor shift, saturation.
#pragma once
#include <cstdint>

// The low w bits of x as a signed value.
static inline int64_t iref_sx(int64_t x, int w) {
  const uint64_t m = (w >= 64) ? ~0ull : ((1ull << w) - 1ull);
  uint64_t u = (uint64_t)x & m;
  if (w < 64 && ((u >> (w - 1)) & 1ull)) u |= ~m;
  return (int64_t)u;
}

// floor(x / 2^s), without relying on >> of a negative value.
static inline int64_t iref_floor_shift(int64_t x, int s) { return x >= 0 ? (x >> s) : ~((~x) >> s); }

// x clamped to the signed w-bit range.
static inline int64_t iref_sat(int64_t x, int w) {
  const int64_t hi = (int64_t(1) << (w - 1)) - 1, lo = -(int64_t(1) << (w - 1));
  return x > hi ? hi : (x < lo ? lo : x);
}

// intMultiplier: the full signed product of two w-bit values.
static inline int64_t iref_mul(int64_t a, int64_t b, int w) { return iref_sx(a, w) * iref_sx(b, w); }

// intAdder: a + b modulo 2^w, as a signed value.
static inline int64_t iref_add(int64_t a, int64_t b, int w) { return iref_sx(iref_sx(a, w) + iref_sx(b, w), w); }

// fxMac: sat_w(floor(a * x / 2^frac) + c), computed exactly in 64 bits.
static inline int64_t iref_fx_mac(int64_t a, int64_t x, int64_t c, int w, int frac) {
  return iref_sat(iref_floor_shift(iref_sx(a, w) * iref_sx(x, w), frac) + iref_sx(c, w), w);
}
