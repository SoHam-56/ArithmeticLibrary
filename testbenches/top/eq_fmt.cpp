// Equivalence of a per-format unit and the generic unit it replaces (eq_tops.sv): every cycle the same done, every done the same result.
// Modes: pairs16 --lo B (a's high byte B, every b: 2^24), pairs8 (every 8-bit pair), unary32 --lo B (every word with high byte B),
// dense2 (floats: every exponent pair x signs x 8 mantissa pairs), corners (integers: every pair of the signed corners),
// random --n N --seed S. Every mode has valid gaps (random: 1 in 8; the others: every 13th cycle), and every vector is still driven.
// Built per top by the Makefile (fmt-eq-build) with -DVTOP=V<top> -DEQ_BITS=<operand bits> [-DCOMB].
#include <cinttypes>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <string>

#include "verilated.h"
#ifndef VTOP
#error "VTOP is not defined"
#endif
#ifndef EQ_BITS
#error "EQ_BITS is not defined"
#endif
#define STR2(x) #x
#define STR(x) STR2(x)
#include STR(VTOP.h)

static uint64_t rs = 0x9E3779B97F4A7C15ULL;
static inline uint64_t rnd() {
  rs ^= rs >> 12, rs ^= rs << 25, rs ^= rs >> 27;
  return rs * 0x2545F4914F6CDD1DULL;
}

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  std::string mode = "random";
  uint64_t n = 0, lo = 0, seed = 1;
  for (int k = 1; k + 1 < argc; k += 2) {
    std::string a = argv[k];
    uint64_t v = strtoull(argv[k + 1], 0, 0);
    if (a == "--mode") mode = argv[k + 1];
    else if (a == "--n") n = v;
    else if (a == "--lo") lo = v;
    else if (a == "--seed") seed = v;
  }
  rs ^= seed * 0xD1B54A32D192ED03ULL;
  const int BITS = EQ_BITS;  // operand bits
  const uint64_t MASK = (1ULL << BITS) - 1;
  static const int64_t CORNERS[] = {0, 1, -1, 2, -2, 3, 127, -128, 128, -129, 255, 32767, -32768, 65535, (1 << 23) - 1, -(1 << 23), 1 << 20,
                                    0x3FFFFFFF, -0x40000000, INT32_MAX, INT32_MIN, INT32_MAX - 1, INT32_MIN + 1, 0x12345678, -0x12345678};
  const uint64_t N_CORNERS = sizeof(CORNERS) / sizeof(CORNERS[0]);
  if (mode == "pairs16" || mode == "unary32") n = 1ULL << 24;
  else if (mode == "pairs8") n = 1ULL << 16;
  else if (mode == "dense2") n = 1ULL << 21;
  else if (mode == "corners") n = N_CORNERS * N_CORNERS;
  if (n == 0) {
    fprintf(stderr, "eq: no vectors\n");
    return 2;
  }
  VerilatedContext* ctx = new VerilatedContext;
  VTOP* t = new VTOP{ctx};
  uint64_t issued = 0, checked = 0, result_diffs = 0, done_diffs = 0;
  auto next = [&](uint64_t& a, uint64_t& b) {
    uint64_t k = issued;
    if (mode == "pairs16") {
      uint64_t x = (lo << 24) + k;
      a = x >> 16, b = x & 0xFFFF;
    } else if (mode == "pairs8") {
      a = k >> 8, b = k & 0xFF;
    } else if (mode == "corners") {
      a = (uint64_t)CORNERS[k / N_CORNERS] & MASK, b = (uint64_t)CORNERS[k % N_CORNERS] & MASK;
    } else if (mode == "unary32") {
      a = (lo << 24) + k, b = 0;
    } else if (mode == "dense2") {
      int man = BITS - 9;
      uint64_t m = k & 7, s = (k >> 3) & 3, ea = (k >> 5) & 255, eb = (k >> 13) & 255, mm = (1ULL << man) - 1, ma, mb;
      if (m == 0) ma = 0, mb = 0;
      else if (m == 1) ma = mm, mb = mm;
      else if (m == 2) ma = 0, mb = mm;
      else if (m == 3) ma = 1ULL << (man - 1), mb = 1;
      else ma = rnd() & mm, mb = rnd() & mm;
      a = ((s & 1) << (BITS - 1)) | (ea << man) | ma;
      b = (((s >> 1) & 1) << (BITS - 1)) | (eb << man) | mb;
    } else {
      a = rnd() & MASK, b = rnd() & MASK;
    }
  };
  char first[8][160];
  int n_first = 0;
#ifdef COMB
  for (; issued < n;) {
    uint64_t a, b;
    next(a, b);
    issued++;
    t->x_i = a;
    t->eval();
    checked++;
    if (t->result_new != t->result_generic) {
      if (n_first < 8) snprintf(first[n_first++], 160, "EQ_DIFF x %#" PRIx64 ": new %#x, generic %#x", a, (unsigned)t->result_new, (unsigned)t->result_generic);
      result_diffs++;
    }
  }
#else
  t->rstn_i = 0, t->valid_i = 0, t->clk_i = 0;
  t->eval();
  for (int k = 0; k < 3; k++) t->clk_i = 1, t->eval(), t->clk_i = 0, t->eval();
  t->rstn_i = 1;
  for (uint64_t cyc = 0; cyc < 4 * n + 64; cyc++) {
    bool gap = (mode == "random") ? (rnd() % 8 == 0) : (cyc % 13 == 12);  // valid gaps in every mode, so done is compared across bubbles
    bool v = issued < n && !gap;
    t->valid_i = v;
    if (v) {
      uint64_t a, b;
      next(a, b);
      t->a_i = a, t->b_i = b;
      issued++;
    }
    t->clk_i = 0, t->eval();
    t->clk_i = 1, t->eval();
    if (t->done_new != t->done_generic) {
      if (n_first < 8) snprintf(first[n_first++], 160, "EQ_DONE cycle %" PRIu64 ": new %d, generic %d", cyc, (int)t->done_new, (int)t->done_generic);
      done_diffs++;
    }
    if (t->done_generic) {
      checked++;
      if (t->result_new != t->result_generic) {
        if (n_first < 8) snprintf(first[n_first++], 160, "EQ_DIFF cycle %" PRIu64 ": new %#" PRIx64 ", generic %#" PRIx64, cyc, (uint64_t)t->result_new, (uint64_t)t->result_generic);
        result_diffs++;
      }
    }
    if (issued == n && checked == n) break;
  }
#endif
  for (int k = 0; k < n_first; k++) printf("%s\n", first[k]);
  printf("EQ %s %s lo %" PRIu64 ": n %" PRIu64 " checked %" PRIu64 " result_diff %" PRIu64 " done_diff %" PRIu64 "\n", STR(VTOP), mode.c_str(), lo, n,
         checked, result_diffs, done_diffs);
  printf("RESULT: %s\n", (checked == n && result_diffs == 0 && done_diffs == 0) ? "PASSED" : "FAILED");
  t->final();
  delete t;
  delete ctx;
  return 0;
}
