// Unit sweep of one Fmt wrapper under one define: streams vectors one per cycle, judges every output against the float64 true
// function with truefn.py's rules (written again here in C), and writes a sample of rows for truefn.py --recheck.
// Built per kind by Fmt/Makefile: -DKIND_<KIND>, fmt_pkg.py --cflags (FMT_<F>, PKG_* widths and latency), the wrapper or test top as top;
// requantize and quantized_add read their parameter sets (real scales and the encoders' words) from --params, written by sweep.py.
#include <cfloat>
#include <cinttypes>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "verilated.h"
#define STR2(x) #x
#define STR(x) STR2(x)
#define CAT(a, b) a##b
#include STR(VTOP.h)

typedef __int128 i128;

// ── the format ──
// Every macro the harness reads comes from the build (fmt_pkg.py --cflags and Fmt/Makefile): none has a default here.
#if defined(FMT_FP32) + defined(FMT_BF16) + defined(FMT_INT8) != 1
#error "exactly one of FMT_FP32, FMT_BF16, FMT_INT8 must be defined"
#endif
#ifndef VTOP
#error "VTOP is not defined"
#endif
#ifndef PKG_DATA_WIDTH
#error "PKG_DATA_WIDTH is not defined"
#endif
#ifndef PKG_ACC_DATA_WIDTH
#error "PKG_ACC_DATA_WIDTH is not defined"
#endif
#ifndef PKG_RESULT_DATA_WIDTH
#error "PKG_RESULT_DATA_WIDTH is not defined"
#endif
#ifndef PKG_BIAS_DATA_WIDTH
#error "PKG_BIAS_DATA_WIDTH is not defined"
#endif
#ifndef PKG_ACTIVATION_DATA_WIDTH
#error "PKG_ACTIVATION_DATA_WIDTH is not defined"
#endif
#ifndef PKG_LATENCY
#error "PKG_LATENCY is not defined"
#endif
#ifndef WRAPPER_DATA_WIDTH
#error "WRAPPER_DATA_WIDTH is not defined"
#endif
#ifndef EXT_DATA_WIDTH
#error "EXT_DATA_WIDTH is not defined"
#endif

#if defined(FMT_INT8)
static const bool FLOATS = false;
static const char* FMT_NAME = "int8";
#elif defined(FMT_BF16)
static const bool FLOATS = true;
static const char* FMT_NAME = "bf16";
#else
static const bool FLOATS = true;
static const char* FMT_NAME = "fp32";
#endif
static const double REL = 0.01, F_FLOOR = 0x1p-126, MIN_NORMAL = 0x1p-126;
static const int I8_FLOOR = 1;

#if defined(KIND_NARROW)
static const char* KIND = "narrow";
#elif defined(KIND_REQUANTIZE)
static const char* KIND = "requantize";
#elif defined(KIND_QUANTIZED_ADD)
static const char* KIND = "quantized_add";
#elif defined(KIND_MUL)  // mul_acc's rule for a widening product, named below
#elif defined(KIND_ADD)  // named below, once WRAPPER_DATA_WIDTH is known
#elif defined(KIND_CMP)
static const char* KIND = "cmp";
#elif defined(KIND_RELU)
static const char* KIND = "relu";
#else
#error "no KIND_<kind>"
#endif

#if (defined(KIND_REQUANTIZE) || defined(KIND_QUANTIZED_ADD)) && !defined(FMT_INT8)
#error "requantize and quantized_add are int8 units: build them with FMT_INT8"
#endif
#if defined(KIND_NARROW) || defined(KIND_CMP) || defined(KIND_RELU)
#define COMB 1
#else
#define COMB 0
#endif
#ifdef OP_DATA_WIDTH
#error "OP_DATA_WIDTH is the old name: the width macro is WRAPPER_DATA_WIDTH"
#endif
#define WIDENING (WRAPPER_DATA_WIDTH == PKG_DATA_WIDTH && EXT_DATA_WIDTH == 32 && WRAPPER_DATA_WIDTH != 32)  // the PE's product: bf16 16 -> 32, int8 8 -> 32
#if defined(KIND_ADD) && defined(LANE_RULE)
static const char* KIND = "add";  // -DLANE_RULE: the lane add's rule at any width (fp32's fmt_add #(32) is GPNAE's add too)
#elif defined(KIND_ADD)
static const char* KIND = (WRAPPER_DATA_WIDTH == PKG_ACC_DATA_WIDTH) ? "acc_add" : "add";  // the accumulator add's rule, or the lane add's
#elif defined(KIND_MUL)
static const char* KIND = WIDENING ? "mul_acc" : "mul";
#endif

static inline uint64_t mask(int w) { return w >= 64 ? ~0ULL : ((1ULL << w) - 1); }
static inline int64_t sign_extend(uint64_t v, int w) { return (int64_t)(v << (64 - w)) >> (64 - w); }
static inline double f32v(uint32_t w) {
  float f;
  memcpy(&f, &w, 4);
  return (double)f;
}
static inline double bf16v(uint32_t w) { return f32v((w & 0xFFFF) << 16); }
#if defined(KIND_ADD) || defined(KIND_MUL)
#define FLOAT_WORD_BITS WRAPPER_DATA_WIDTH  // the wrappers: the width they were built at
#else
#define FLOAT_WORD_BITS PKG_DATA_WIDTH  // the test tops: the format's word
#endif
static inline double decode_word(uint64_t w) { return FLOAT_WORD_BITS == 16 ? bf16v((uint32_t)w) : f32v((uint32_t)w); }  // a judged float word
static inline double ftz(double v) { return fabs(v) < MIN_NORMAL ? copysign(0.0, v) : v; }
static const double FMAX32 = FLT_MAX;
static const double FMAXD = (FLOAT_WORD_BITS == 16) ? 0x1.fep127 : FLT_MAX;

struct Verdict {
  bool ok;
  double e;
};
static bool floor_only = false;  // the last vector was decided by the floor: |t| within one step of zero, or an error over tol |t| within one step

// floats: truefn.float_rule
static inline Verdict float_rule(double t, double o, double fm) {
  if (std::isnan(t)) return {std::isnan(o), std::isnan(o) ? 0.0 : INFINITY};
  if (std::isinf(t)) return {o == t, o == t ? 0.0 : INFINITY};
  if (fabs(t) > fm) {
    bool top = !std::isnan(o) && (fabs(o) == fm || std::isinf(o)) && (std::signbit(o) == std::signbit(t));
    return {top, top ? 0.0 : INFINITY};
  }
  if (!std::isfinite(o)) return {false, INFINITY};
  if (fabs(o - t) <= F_FLOOR) {  // within 2^-126 of t: the floor, at every |t| (truefn.float_rule)
    floor_only = fabs(t) <= F_FLOOR || fabs(o - t) > REL * fabs(t);
    return {true, 0.0};
  }
  if (t == 0) return {false, INFINITY};
  double e = fabs(o - t) / fabs(t);
  return {e <= REL, e};
}

// accumulation: truefn.acc_rule
static inline Verdict acc_rule(double t, double o, double scale, double fm) {
  if (std::isnan(t) || std::isinf(t) || (fabs(t) > fm)) return float_rule(t, o, fm);
  if (!std::isfinite(o)) return {false, INFINITY};
  double err = fabs(o - t);
  bool ok = err <= std::fmax(REL * scale, F_FLOOR);
  floor_only = ok && (fabs(t) <= F_FLOOR || err > REL * scale);
  double e = err <= F_FLOOR ? 0.0 : (scale > 0 ? err / scale : INFINITY);  // a pass on the floor reports 0 (truefn.acc_rule)
  return {ok, e};
}

static inline Verdict exact(bool ok, double e) { return {ok, ok ? 0.0 : e}; }
static inline bool same_value(double a, double b) { return a == b || (std::isnan(a) && std::isnan(b)); }

// ── a vector, and how this kind drives, reads and judges it ──
struct Vec {
  uint64_t a, b, c;
  int param_set;  // parameter set (requantize, quantized_add)
};
// requantize: bits(s), m, e, zp, lo, hi; quantized_add: bits(r1), bits(r2), m1, m2, e, z1, z2, zo, lo, hi (a real as its float64 bits)
static std::vector<std::vector<int64_t>> PARAM_SETS;
static std::vector<std::vector<uint32_t>> PARAM_WORDS;  // each set packed as the params_i port
static inline double real_of(int64_t bits) {
  double d;
  memcpy(&d, &bits, 8);
  return d;
}

#if defined(KIND_QUANTIZED_ADD) || defined(KIND_MUL) || defined(KIND_ADD) || defined(KIND_CMP)
#define NOPS 2
#elif defined(KIND_RELU)
#define NOPS 2
#else
#define NOPS 1
#endif

// operand widths
#if defined(KIND_QUANTIZED_ADD) || defined(KIND_CMP) || defined(KIND_RELU)
static const int OPERAND_BITS = PKG_DATA_WIDTH;
#elif defined(KIND_ADD)
static const int OPERAND_BITS = WRAPPER_DATA_WIDTH;
#elif defined(KIND_NARROW)
static const int OPERAND_BITS = PKG_ACC_DATA_WIDTH;
#elif defined(KIND_REQUANTIZE)
static const int OPERAND_BITS = PKG_RESULT_DATA_WIDTH;
#elif defined(KIND_MUL)
static const int OPERAND_BITS = WRAPPER_DATA_WIDTH;
#else
static const int OPERAND_BITS = PKG_ACTIVATION_DATA_WIDTH;
#endif
#if defined(KIND_MUL)
static const int RESULT_BITS = EXT_DATA_WIDTH;
#elif defined(KIND_ADD)
static const int RESULT_BITS = WRAPPER_DATA_WIDTH;
#elif defined(KIND_NARROW)
static const int RESULT_BITS = PKG_RESULT_DATA_WIDTH;
#elif defined(KIND_CMP)
static const int RESULT_BITS = 1;
#else
static const int RESULT_BITS = PKG_DATA_WIDTH;
#endif

static inline void drive(VTOP* t, const Vec& v) {
#if defined(KIND_NARROW) || defined(KIND_REQUANTIZE)
  t->x_i = v.a;
#elif defined(KIND_RELU)
  t->x_i = v.a;
  t->zero_point_i = v.b;
#else
  t->a_i = v.a;
  t->b_i = v.b;
#endif
#if defined(KIND_REQUANTIZE)
  t->params_i = ((uint64_t)PARAM_WORDS[v.param_set][1] << 32) | PARAM_WORDS[v.param_set][0];  // requant_params_t, 54 bits
#elif defined(KIND_QUANTIZED_ADD)
  for (int k = 0; k < 4; k++) t->params_i[k] = PARAM_WORDS[v.param_set][k];  // add_params_t, 110 bits
#endif
}

static inline uint64_t read_y(VTOP* t) {
#if defined(KIND_CMP)
  return t->greater_o;
#elif defined(KIND_MUL)
  return t->product_o;
#elif defined(KIND_ADD)
  return t->sum_o;
#else
  return (uint64_t)t->y_o & mask(RESULT_BITS);
#endif
}

static double code_deviation = -1, code_relative = -1;  // requantize, quantized_add: the last row's |hw - t| in steps, and / |t| where the tolerance decides
static bool ungated = false;  // the last judged vector has an input the kind does not gate (cmp, relu: a NaN operand)

static inline Verdict judge(const Vec& v, uint64_t y) {
#if defined(KIND_NARROW)
#if defined(FMT_BF16)
  double x = ftz(f32v((uint32_t)v.a));
  float xf = (float)x;
  uint32_t u;
  memcpy(&u, &xf, 4);
  uint32_t want = std::isnan(x) ? 0x7FC0 : (((uint64_t)u + 0x7FFF + ((u >> 16) & 1)) >> 16) & 0xFFFF;
  double wv = bf16v(want), yv = bf16v((uint32_t)y);
  return exact(same_value(wv, yv), fabs(wv - yv));
#else
  return exact((y & 0xFFFFFFFF) == (v.a & 0xFFFFFFFF), 1.0);
#endif
#elif defined(KIND_REQUANTIZE) || defined(KIND_QUANTIZED_ADD)
  const std::vector<int64_t>& set_words = PARAM_SETS[v.param_set];
#if defined(KIND_REQUANTIZE)
  const double zero_point = (double)set_words[3], clamp_low = (double)set_words[4], clamp_high = (double)set_words[5];
  double true_code = (double)sign_extend(v.a, 32) * real_of(set_words[0]) + zero_point;  // truth.requant_true: acc s + zp, float64
#else
  const double zero_point = (double)set_words[7], clamp_low = (double)set_words[8], clamp_high = (double)set_words[9];
  double true_code = (real_of(set_words[0]) * (double)(sign_extend(v.a, 8) - set_words[5]) +
                      real_of(set_words[1]) * (double)(sign_extend(v.b, 8) - set_words[6])) / 1.0 + zero_point;  // truth.add_true, s_out 1
#endif
  true_code = true_code < clamp_low ? clamp_low : true_code > clamp_high ? clamp_high : true_code;  // clamped to the output range
  const double deviation = fabs((double)sign_extend(y, 8) - true_code), true_magnitude = fabs(true_code - zero_point);  // |hw - t|, |t| in steps
  const bool ok = deviation <= std::fmax(REL * true_magnitude, (double)I8_FLOOR);  // the floor of one step at every |t|
  floor_only = ok && (true_magnitude <= I8_FLOOR || deviation > REL * true_magnitude);
  code_deviation = deviation;  // reported in steps over every row, and in percent of |t| where the tolerance decides
  code_relative = (!floor_only && true_magnitude > 0) ? deviation / true_magnitude : -1;
  return {ok, deviation <= I8_FLOOR ? 0.0 : (true_magnitude > 0 ? deviation / true_magnitude : INFINITY)};
#elif defined(KIND_MUL)
  if (FLOATS && EXT_DATA_WIDTH == 32 && WRAPPER_DATA_WIDTH == 16) return float_rule(ftz(decode_word(v.a)) * ftz(decode_word(v.b)), f32v((uint32_t)y), FMAX32);  // the exact fp32 product
  if (FLOATS) return float_rule(ftz(decode_word(v.a)) * ftz(decode_word(v.b)), decode_word(y), FMAXD);
  i128 t = (i128)sign_extend(v.a, WRAPPER_DATA_WIDTH) * sign_extend(v.b, WRAPPER_DATA_WIDTH);  // int8: exact, sign-extended to EXT_DATA_WIDTH
  return exact((i128)sign_extend(y, EXT_DATA_WIDTH) == t, 1.0);
#elif defined(KIND_ADD)
#ifdef LANE_RULE
  const bool acc = !FLOATS;  // int32 sums stay exact; floats take the lane rule on |t|
#else
  const bool acc = WRAPPER_DATA_WIDTH == PKG_ACC_DATA_WIDTH;
#endif
  if (acc) {  // the accumulator add: fp32 words within max(REL (|a| + |b|), F_FLOOR), int32 exact modulo 2^32
    if (FLOATS) {
      double a = ftz(f32v((uint32_t)v.a)), b = ftz(f32v((uint32_t)v.b));
      return acc_rule(a + b, f32v((uint32_t)y), fabs(a) + fabs(b), FMAX32);
    }
    int64_t t = sign_extend((uint64_t)(sign_extend(v.a, 32) + sign_extend(v.b, 32)), 32);
    return exact(sign_extend(y, 32) == t, fabs((double)(sign_extend(y, 32) - t)));
  }
  return float_rule(ftz(decode_word(v.a)) + ftz(decode_word(v.b)), decode_word(y), FMAXD);  // the lane add
#elif defined(KIND_CMP)
  if (FLOATS) {
    double a = ftz(decode_word(v.a)), b = ftz(decode_word(v.b));
    if (std::isnan(a) || std::isnan(b)) {
      ungated = true;
      return {true, 0.0};
    }
    double m = a > b ? a : b, ch = y ? a : b;
    return exact(m == ch, fabs(m - ch));
  }
  bool gt = sign_extend(v.a, 8) > sign_extend(v.b, 8);
  return exact((y != 0) == gt, 1.0);
#elif defined(KIND_RELU)
  if (FLOATS) {
    double x = ftz(decode_word(v.a));
    if (std::isnan(x)) {
      ungated = true;
      return {true, 0.0};
    }
    return float_rule(x > 0 ? x : 0.0, decode_word(y), FMAXD);
  }
  int64_t q = sign_extend(v.a, 8), zp = sign_extend(v.b, 8), want = q > zp ? q : zp;  // max(q, zp)
  return exact(sign_extend(y, 8) == want, fabs((double)(sign_extend(y, 8) - want)));
#endif
}

// ── vector sources ──
static uint64_t rs = 0x9E3779B97F4A7C15ULL, rs2 = 0x632BE59BD9B4E019ULL;
static inline uint64_t xorshift(uint64_t& s) {  // xorshift64*
  s ^= s >> 12, s ^= s << 25, s ^= s >> 27;
  return s * 0x2545F4914F6CDD1DULL;
}
static inline uint64_t rnd() { return xorshift(rs); }  // vectors
static inline uint64_t rnd2() { return xorshift(rs2); }  // the sample's perturbations, apart so a sample never changes the vectors
static inline uint64_t encode_word(double v) {  // a value as a DATA_W float word, rounded to nearest even
  float f = (float)v;
  uint32_t u;
  memcpy(&u, &f, 4);
  if (PKG_DATA_WIDTH == 32) return u;
  if ((u & 0x7FFFFFFF) > 0x7F800000) return 0x7FC0;
  return (((uint64_t)u + 0x7FFF + ((u >> 16) & 1)) >> 16) & 0xFFFF;
}

#if defined(KIND_REQUANTIZE)
static const int64_t REQ_DENSE = 1 << 20, REQ_AIM = 640 * 8, REQ_RANDOM = 1 << 14;
static const uint64_t REQ_N_DENSE = 2 * REQ_DENSE + 1, REQ_N_AIM = 3 * (2 * REQ_AIM + 1);
static const int64_t REQ_ENDS[] = {INT32_MIN, INT32_MIN + 1, INT32_MAX - 1, INT32_MAX};
static const uint64_t REQ_PER_SET = REQ_N_DENSE + REQ_N_AIM + REQ_RANDOM + 4;
static inline uint64_t splitmix(uint64_t x) {
  x += 0x9E3779B97F4A7C15ULL;
  x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
  x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
  return x ^ (x >> 31);
}
static int64_t requant_acc(int set, uint64_t j) {
  if (j < REQ_N_DENSE) return (int64_t)j - REQ_DENSE;
  j -= REQ_N_DENSE;
  if (j < REQ_N_AIM) {  // acc s just below, at and just above each eighth of a code from -640 to 640
    double c = (double)((int64_t)(j / 3) - REQ_AIM) / 8.0, a = std::nearbyint(c / real_of(PARAM_SETS[set][0])) + (double)((int64_t)(j % 3) - 1);
    return a > (double)INT32_MAX ? INT32_MAX : a < (double)INT32_MIN ? INT32_MIN : (int64_t)a;
  }
  j -= REQ_N_AIM;
  if (j < (uint64_t)REQ_RANDOM) return sign_extend(splitmix(((uint64_t)set << 32) | j), 32);
  return REQ_ENDS[j - REQ_RANDOM];
}
#endif

struct Source {
  std::string mode;
  uint64_t i = 0, n = 0, lo = 0;
  int float_width = 0;  // float operand width (32 or 16), 0 for integers
  bool next(Vec& v);
};

static const int64_t CORNERS32[] = {0, 1, -1, 2, -2, 127, -128, 255, 32767, -32768, 65535, 1 << 20, -(1 << 20), 0x3FFFFFFF, -0x40000000,
                                    INT32_MAX, INT32_MIN, INT32_MAX - 1, INT32_MIN + 1, 0x12345678, -0x12345678};
static const int N_CORNERS32 = sizeof(CORNERS32) / sizeof(CORNERS32[0]);

bool Source::next(Vec& v) {
  if (i >= n) return false;
  uint64_t k = i++;
  v.c = 0;
  v.param_set = 0;
  if (mode == "pairs16") {  // a's high byte from lo, every b: n = 2^24 per high byte
    uint64_t x = (lo << 24) + k;
    v.a = x >> 16, v.b = x & 0xFFFF;
  } else if (mode == "pairs8") {  // every 8-bit pair
    v.a = k >> 8, v.b = k & 0xFF;
  } else if (mode == "unary32") {  // every 32-bit word with high byte from lo
    v.a = (lo << 24) + k, v.b = 0;
  } else if (mode == "unary16" || mode == "unary8") {
    v.a = k, v.b = 0;
  } else if (mode == "dense2" || mode == "dense1") {  // every exponent (pair) x signs x 8 mantissas (pairs)
    int man = float_width - 9;
    uint64_t m = k & 7, s = (k >> 3) & 3, ea = (k >> 5) & 255, eb = (k >> 13) & 255;
    uint64_t mm = mask(man), ma, mb;
    if (m == 0) ma = 0, mb = 0;
    else if (m == 1) ma = mm, mb = mm;
    else if (m == 2) ma = 0, mb = mm;
    else if (m == 3) ma = 1ULL << (man - 1), mb = 1;
    else ma = rnd() & mm, mb = rnd() & mm;
    v.a = ((s & 1) << (float_width - 1)) | (ea << man) | ma;
    v.b = (((s >> 1) & 1) << (float_width - 1)) | (eb << man) | mb;
    v.c = (rnd() & 1) ? v.a : v.b;
  } else if (mode == "dense_int") {  // every pair of the int32 corners, then random
    uint64_t p = k % (N_CORNERS32 * N_CORNERS32);
    v.a = (uint64_t)CORNERS32[p / N_CORNERS32] & mask(OPERAND_BITS), v.b = (uint64_t)CORNERS32[p % N_CORNERS32] & mask(OPERAND_BITS);
  } else if (mode == "random") {
    v.a = rnd() & mask(OPERAND_BITS), v.b = rnd() & mask(OPERAND_BITS), v.c = rnd() & mask(OPERAND_BITS);
  } else if (mode == "cancel") {  // floats: b (or c) close to -a (or -x acc), so the result cancels
    double x = ldexp(1.0 + (rnd() % 1000000) / 1e6, (int)(rnd() % 60) - 30) * ((rnd() & 1) ? -1 : 1);
    double d = ldexp((double)(rnd() % 1000) / 1000.0, -(int)(rnd() % 30));
    if (OPERAND_BITS == 32) {  // fp32 words: the accumulator add, and every fp32 kind
      float xf = (float)x, yf = (float)(-(double)(float)x * (1.0 + d));
      uint32_t ua, ub;
      memcpy(&ua, &xf, 4);
      memcpy(&ub, &yf, 4);
      v.a = ua, v.b = ub;
    } else {
      v.a = encode_word(x), v.b = encode_word(-decode_word(encode_word(x)) * (1.0 + d));
    }
  } else if (mode == "params") {  // every set x its vectors: requantize REQ_PER_SET accumulators, quantized_add every (q1, q2)
#if defined(KIND_REQUANTIZE)
    v.param_set = (int)(k / REQ_PER_SET);
    v.a = (uint64_t)requant_acc(v.param_set, k % REQ_PER_SET) & 0xFFFFFFFF;
#else
    v.param_set = (int)(k >> 16);
    v.a = (k >> 8) & 0xFF, v.b = k & 0xFF;
#endif
  } else if (mode == "params_random") {  // a random set and a random accumulator or pair
    v.param_set = (int)(rnd() % PARAM_SETS.size());
    v.a = rnd() & mask(OPERAND_BITS), v.b = rnd() & mask(OPERAND_BITS);
  } else {
    fprintf(stderr, "sweep: unknown mode %s\n", mode.c_str());
    exit(2);
  }
  return true;
}

// ── parameter sets, from --params (sweep.py writes them with ipu.encode_scale and ipu.encode_add) ──
static void pack(const std::vector<int64_t>& p, const int* widths, int nf) {  // fields MSB first, as the packed struct
  std::vector<uint32_t> w(5, 0);
  int pos = 0;
  for (int f = nf - 1; f >= 0; f--) {
    for (int b = 0; b < widths[f]; b++, pos++)
      if (((uint64_t)p[f] >> b) & 1) w[pos / 32] |= 1u << (pos % 32);
  }
  PARAM_WORDS.push_back(w);
}
static void load_params(const std::string& path) {
  FILE* f = fopen(path.c_str(), "r");
  if (!f) {
    fprintf(stderr, "sweep: cannot read --params %s\n", path.c_str());
    exit(2);
  }
  char line[512];
  while (fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    std::vector<int64_t> p;
    char* c = line;
    for (char* tok = strtok(c, " \t\n"); tok; tok = strtok(nullptr, " \t\n")) {
      if (strchr(tok, 'p') || strchr(tok, '.')) {  // a real (C99 hex float), kept as its float64 bits
        double d = strtod(tok, nullptr);
        int64_t bits;
        memcpy(&bits, &d, 8);
        p.push_back(bits);
      } else p.push_back(strtoll(tok, nullptr, 0));
    }
#if defined(KIND_REQUANTIZE)
    static const int FIELD_BITS[5] = {24, 6, 8, 8, 8};  // requant_params_t: mantissa, shift, zero_point, act_min, act_max
    if (p.size() != 6 || p[1] < 0 || p[1] >= (1 << 24) || p[2] < 0 || p[2] > 55) {
      fprintf(stderr, "sweep: requantize set needs: s m e zp lo hi with m < 2^24 and e <= 55: %s\n", line);
      exit(2);
    }
    PARAM_SETS.push_back(p);
    pack({p[1], p[2], p[3], p[4], p[5]}, FIELD_BITS, 5);
#else
    static const int FIELD_BITS[8] = {8, 8, 32, 32, 6, 8, 8, 8};  // add_params_t: in1/in2 zero points, mantissas, shift, out zero point, clamp
    if (p.size() != 10 || p[4] < 0 || p[4] > 41) {
      fprintf(stderr, "sweep: quantized_add set needs: r1 r2 m1 m2 e z1 z2 zo lo hi with e <= 41: %s\n", line);
      exit(2);
    }
    PARAM_SETS.push_back(p);
    pack({p[5], p[6], p[2], p[3], p[4], p[7], p[8], p[9]}, FIELD_BITS, 8);
#endif
  }
  fclose(f);
  if (PARAM_SETS.empty()) {
    fprintf(stderr, "sweep: no sets in --params %s\n", path.c_str());
    exit(2);
  }
}

// ── the run ──
int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  Source src;
  std::string sample_path, params_path;
  bool size_only = false;  // --size: print the mode's vector count and stop
  uint64_t sample_n = 0, seed = 1, first_i = 0, count = 0;
  long long n_ungated = 0;  // every ungated vector: NaN operands (cmp, relu)
  long long n_floor_only = 0;  // rows that pass only on the floor
  src.mode = "random";
  for (int k = 1; k < argc; k++) {
    std::string a = argv[k];
    auto val = [&](void) { return std::string(k + 1 < argc ? argv[++k] : ""); };
    if (a == "--mode") src.mode = val();
    else if (a == "--n") src.n = strtoull(val().c_str(), 0, 0);
    else if (a == "--lo") src.lo = strtoull(val().c_str(), 0, 0);
    else if (a == "--seed") seed = strtoull(val().c_str(), 0, 0);
    else if (a == "--sample") sample_path = val();
    else if (a == "--sample-n") sample_n = strtoull(val().c_str(), 0, 0);
    else if (a == "--first") first_i = strtoull(val().c_str(), 0, 0);
    else if (a == "--count") count = strtoull(val().c_str(), 0, 0);
    else if (a == "--params") params_path = val();
    else if (a == "--size") size_only = true;
  }
  rs ^= seed * 0xD1B54A32D192ED03ULL;
  for (int k = 0; k < 8; k++) rnd();
  src.float_width = FLOATS ? (OPERAND_BITS == 32 ? 32 : 16) : 0;
#if defined(KIND_REQUANTIZE) || defined(KIND_QUANTIZED_ADD)
  if (params_path.empty()) {
    fprintf(stderr, "sweep: %s needs --params\n", KIND);
    return 2;
  }
  load_params(params_path);
#endif
  if (src.mode == "pairs16") src.n = 1ULL << 24;
  else if (src.mode == "pairs8") src.n = 1ULL << 16;
  else if (src.mode == "unary32") src.n = 1ULL << 24;
  else if (src.mode == "unary16") src.n = 1ULL << 16;
  else if (src.mode == "unary8") src.n = 1ULL << 8;
  else if (src.mode == "dense2") src.n = 1ULL << 21;
  else if (src.mode == "dense1") src.n = 1ULL << 13;
  else if (src.mode == "dense_int" && src.n == 0) src.n = N_CORNERS32 * N_CORNERS32;
#if defined(KIND_REQUANTIZE)
  else if (src.mode == "params") src.n = PARAM_SETS.size() * REQ_PER_SET;
#elif defined(KIND_QUANTIZED_ADD)
  else if (src.mode == "params") src.n = PARAM_SETS.size() * (1ULL << 16);
#endif
  if (src.n == 0) {
    fprintf(stderr, "sweep: no vectors (--n for mode %s)\n", src.mode.c_str());
    return 2;
  }
  if (size_only) {
    printf("SIZE %" PRIu64 "\n", src.n);
    return 0;
  }
  if (count) {  // a window of the mode's vectors: [first, first + count)
    src.i = first_i;
    src.n = first_i + count < src.n ? first_i + count : src.n;
  }
  const uint64_t want_n = src.n - src.i;
  uint64_t stride = sample_n ? (want_n / sample_n > 0 ? want_n / sample_n : 1) : 0;
  FILE* sf = sample_path.empty() ? nullptr : fopen(sample_path.c_str(), "w");
  if (sf) fprintf(sf, "# kind fmt a b c y ok w p0..p10 (harness verdicts; every second row a perturbed output)\n");

  VerilatedContext* ctx = new VerilatedContext;
  VTOP* top = new VTOP{ctx};
  long long n = 0, miss = 0, lat_err = 0, cycles = 0;
  double worst = -1, worst_steps = -1, worst_relative = -1;  // the last two for requantize and quantized_add only (-1 elsewhere)
  long long relative_rows = 0;  // their rows the 1% tolerance decides
  Vec wv{};
  uint64_t wy = 0;
  std::vector<std::string> first;
  auto record = [&](const Vec& v, uint64_t y, uint64_t idx) {
    ungated = false;
    floor_only = false;
    code_deviation = code_relative = -1;
    Verdict r = judge(v, y);
    n_ungated += ungated;
    n_floor_only += floor_only;
    n++;
    double e = std::isnan(r.e) ? INFINITY : r.e;
    if (e > worst) worst = e, wv = v, wy = y;
    worst_steps = std::fmax(worst_steps, code_deviation);
    if (code_relative >= 0) worst_relative = std::fmax(worst_relative, code_relative), relative_rows++;
    char buf[200];
    if (!r.ok) {
      miss++;
      if (first.size() < 16) {
        snprintf(buf, sizeof buf, "SWEEP_MISS %s %s: a %#" PRIx64 " b %#" PRIx64 " c %#" PRIx64 " param_set %d -> %#" PRIx64 " (e %.6g)", KIND, FMT_NAME,
                 v.a, v.b, v.c, v.param_set, y, r.e);
        first.push_back(buf);
      }
    }
    if (sf && stride && idx % stride == 0) {
      uint64_t yp = y ^ (1ULL << (rnd2() % RESULT_BITS));
      Verdict rp = judge(v, yp);
      for (int t = 0; t < 2; t++) {
        fprintf(sf, "%s %s %#" PRIx64 " %#" PRIx64 " %#" PRIx64 " %#" PRIx64 " %d %d", KIND, FMT_NAME, v.a, v.b, v.c, t ? yp : y, t ? rp.ok : r.ok, WRAPPER_DATA_WIDTH);
        for (int f = 0; f < 11; f++) fprintf(sf, " %" PRId64, (v.param_set < (int)PARAM_SETS.size() && f < (int)PARAM_SETS[v.param_set].size()) ? PARAM_SETS[v.param_set][f] : 0);
        fprintf(sf, "\n");
      }
    }
  };
  Vec v;
#if COMB
  while (src.next(v)) {
    drive(top, v);
    top->eval();
    record(v, read_y(top), (uint64_t)n);
  }
#else
  const int RING = 64;
  Vec ring[RING];
  long long ring_cyc[RING];
  uint64_t issued = 0, retired = 0;
  top->rstn_i = 0;
  top->valid_i = 0;
  top->clk_i = 0;
  top->eval();
  for (int k = 0; k < 3; k++) {
    top->clk_i = 1;
    top->eval();
    top->clk_i = 0;
    top->eval();
  }
  top->rstn_i = 1;
  bool more = true;
  for (long long cyc = 0;; cyc++) {
    bool have = more && src.next(v);
    more = have;
    top->valid_i = have;
    if (have) {
      ring[issued % RING] = v, ring_cyc[issued % RING] = cyc;
      issued++;
      drive(top, v);
    }
    top->clk_i = 0;
    top->eval();
    if (PKG_LATENCY == 0 && top->done_o) {
      record(ring[retired % RING], read_y(top), retired);
      retired++;
    }
    top->clk_i = 1;
    top->eval();
    if (PKG_LATENCY > 0 && top->done_o) {
      long long lat = cyc - ring_cyc[retired % RING] + 1;
      if (lat != PKG_LATENCY && ++lat_err <= 5) printf("SWEEP_LATENCY %s %s: %lld cycles, the package says %d\n", KIND, FMT_NAME, lat, PKG_LATENCY);
      record(ring[retired % RING], read_y(top), retired);
      retired++;
    }
    cycles = cyc + 1;
    if (!have && retired == issued) break;
    if (issued - retired > RING - 4 || cyc > (long long)(4 * src.n + 1000)) {
      printf("SWEEP_STALL %s %s: %" PRIu64 " issued, %" PRIu64 " done at cycle %lld\n", KIND, FMT_NAME, issued, retired, cyc);
      lat_err++;
      break;
    }
  }
#endif
  if (sf) fclose(sf);
  for (auto& s : first) printf("%s\n", s.c_str());
  printf("SWEEP %s %s %s lo %" PRIu64 " first %" PRIu64 ": n %lld miss %lld worst %.6g at a %#" PRIx64 " b %#" PRIx64 " c %#" PRIx64 " param_set %d -> %#" PRIx64
         " ungated %lld floor_only %lld latency_errors %lld cycles %lld worst_steps %.6g worst_relative %.6g relative_rows %lld data_width %d"
         " ext_data_width %d\n",
         KIND, FMT_NAME, src.mode.c_str(), src.lo, first_i, n, miss, worst, wv.a, wv.b, wv.c, wv.param_set, wy, n_ungated, n_floor_only, lat_err, cycles, worst_steps, worst_relative, relative_rows,
         (int)WRAPPER_DATA_WIDTH, (int)EXT_DATA_WIDTH);
  bool all_floor = n > n_ungated && n_floor_only == n - n_ungated;  // a log note only: sweep.py reads floor_only from the SWEEP line
  if (all_floor) printf("SWEEP_ALL_FLOOR %s %s: all %lld gated rows are decided by the floor\n", KIND, FMT_NAME, n - n_ungated);
  bool ok = (uint64_t)n == want_n && miss == 0 && lat_err == 0;
  printf("RESULT: %s\n", ok ? "PASSED" : "FAILED");
  top->final();
  delete top;
  delete ctx;
  return 0;
}
