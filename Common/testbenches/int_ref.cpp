// DPI wrappers of int_ref_core.h for the integer-unit testbenches.
#include <svdpi.h>
#include "int_ref_core.h"

extern "C" int c_int_mul(int a, int b, int w) { return (int)iref_mul(a, b, w); }

extern "C" int c_int_add(int a, int b, int w) { return (int)iref_add(a, b, w); }

extern "C" int c_fx_mac(int a, int x, int c, int w, int frac) { return (int)iref_fx_mac(a, x, c, w, frac); }
