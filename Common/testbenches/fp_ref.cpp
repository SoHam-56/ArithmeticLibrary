// DPI wrappers of fp_ref_core.h for the float-unit testbenches.
#include <svdpi.h>
#include "fp_ref_core.h"

extern "C" int c_fp_mul(int a, int b, int man_w, int *flags) {
  return (int)fpref_op(0, (uint32_t)a, (uint32_t)b, man_w, flags);
}

extern "C" int c_fp_add(int a, int b, int man_w, int *flags) {
  return (int)fpref_op(1, (uint32_t)a, (uint32_t)b, man_w, flags);
}
