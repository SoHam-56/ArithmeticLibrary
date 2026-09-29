// Writes a vectors file for the integer units' Vivado testbenches, operands then result in hex per line; args: mul|add|fxmac COUNT OUT.
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include "int_ref_core.h"

// A uniform w-bit pattern (w <= 32) as a signed value.
static int64_t rnd(int w) {
  const uint64_t r = (uint64_t)rand() ^ ((uint64_t)rand() << 16) ^ ((uint64_t)rand() << 32);
  return iref_sx((int64_t)r, w);
}

int main(int argc, char **argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: gen_int_vectors mul|add|fxmac COUNT OUT\n");
    return 1;
  }
  const int op = !strcmp(argv[1], "mul") ? 0 : (!strcmp(argv[1], "add") ? 1 : (!strcmp(argv[1], "fxmac") ? 2 : -1));
  const int count = atoi(argv[2]);
  if (op < 0 || count <= 0) {
    fprintf(stderr, "gen_int_vectors: unknown unit %s or bad count %s\n", argv[1], argv[2]);
    return 1;
  }
  const int w = op == 0 ? 8 : (op == 1 ? 32 : 16), frac = 11, rw = op == 0 ? 2 * w : w, d = w / 4, rd = rw / 4;
  const uint64_t m = (1ull << w) - 1ull, rm = (1ull << rw) - 1ull;
  const int64_t mx = (int64_t(1) << (w - 1)) - 1, mn = -(int64_t(1) << (w - 1));
  // Corners first: zero, one, the extremes and their neighbours, and for fxMac 1.0 and its neighbours in Q4.11.
  std::vector<int64_t> cv = {0, 1, -1, 2, -2, mx, mn, mx - 1, mn + 1};
  if (op == 2) cv.insert(cv.end(), {int64_t(2048), int64_t(-2048), int64_t(2047), int64_t(-2049)});
  std::vector<std::array<int64_t, 3>> v;
  for (int64_t a : cv)
    for (int64_t b : cv) {
      if (op == 2) {
        for (int64_t c : {int64_t(0), mx, mn}) v.push_back({a, b, c});
      } else {
        v.push_back({a, b, 0});
      }
    }
  srand(42);
  while ((int)v.size() < count) v.push_back({rnd(w), rnd(w), rnd(w)});
  v.resize(count);
  FILE *out = fopen(argv[3], "w");
  if (!out) {
    perror(argv[3]);
    return 1;
  }
  for (const auto &t : v) {
    const int64_t r = op == 0 ? iref_mul(t[0], t[1], w) : (op == 1 ? iref_add(t[0], t[1], w) : iref_fx_mac(t[0], t[1], t[2], w, frac));
    const unsigned long long a = (uint64_t)t[0] & m, b = (uint64_t)t[1] & m, c = (uint64_t)t[2] & m, res = (uint64_t)r & rm;
    if (op == 2)
      fprintf(out, "%0*llx%0*llx%0*llx%0*llx\n", d, a, d, b, d, c, rd, res);
    else
      fprintf(out, "%0*llx%0*llx%0*llx\n", d, a, d, b, rd, res);
  }
  fclose(out);
  printf("%s: %d %s vectors\n", argv[3], count, argv[1]);
  return 0;
}
