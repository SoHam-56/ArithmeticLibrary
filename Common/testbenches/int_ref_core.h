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

// Round half up of x / 2^s, floor(x / 2^s + 1/2), on 128 bits; 0 <= s <= 125.
static inline __int128 iref_round_half_up(__int128 x, int s) {
  if (s == 0) return x;
  const __int128 t = x + ((__int128)1 << (s - 1));
  return t >= 0 ? (t >> s) : -(((-t) + (((__int128)1 << s) - 1)) >> s);  // floor of t / 2^s
}

// int8Requantizer: clamp(round half up of acc * m / 2^e, + zp, then max lo, min hi), from the definition (no intermediate width).
static inline int64_t iref_requantize(int64_t acc, uint64_t m, int e, int64_t zp, int64_t lo, int64_t hi) {
  __int128 r = iref_round_half_up((__int128)iref_sx(acc, 32) * (__int128)m, e) + iref_sx(zp, 8);
  if (r < iref_sx(lo, 8)) r = iref_sx(lo, 8);
  if (r > iref_sx(hi, 8)) r = iref_sx(hi, 8);
  return (int64_t)r;
}

// int8QuantizedAdder: clamp(round half up of ((q1 - z1) m1 + (q2 - z2) m2) / 2^e, + zo, then max lo, min hi), from the definition.
static inline int64_t iref_qadd(int64_t q1, int64_t q2, int64_t z1, int64_t z2, uint64_t m1, uint64_t m2, int e, int64_t zo, int64_t lo,
                                int64_t hi) {
  const __int128 s = (__int128)(iref_sx(q1, 8) - iref_sx(z1, 8)) * (__int128)m1 + (__int128)(iref_sx(q2, 8) - iref_sx(z2, 8)) * (__int128)m2;
  __int128 r = iref_round_half_up(s, e) + iref_sx(zo, 8);
  if (r < iref_sx(lo, 8)) r = iref_sx(lo, 8);
  if (r > iref_sx(hi, 8)) r = iref_sx(hi, 8);
  return (int64_t)r;
}
