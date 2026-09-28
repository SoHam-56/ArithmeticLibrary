// Writes a vectors file for the Vivado testbenches, A B Res Flags in hex per line; args: mul|add MAN_W COUNT OUT.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include "fp_ref_core.h"

int main(int argc, char **argv) {
  if (argc != 5) {
    fprintf(stderr, "usage: gen_vectors mul|add MAN_W COUNT OUT\n");
    return 1;
  }
  const int op = strcmp(argv[1], "add") == 0, man_w = atoi(argv[2]), count = atoi(argv[3]);
  const int w = 9 + man_w, d = (w + 3) / 4;
  const uint32_t mask = (w == 32) ? 0xFFFFFFFFu : ((1u << w) - 1u), sh = 23 - man_w;
  // The fp32 generators' corners, narrowed: zeros, 1.0, infinities, NaN, cancellation, a subnormal input.
  const uint32_t corner[][2] = {{0x00000000u, 0x00000000u}, {0x3F800000u, 0x00000000u}, {0x7F800000u, 0x3F800000u},
                                {0x7F800000u, 0xFF800000u}, {0x7FC00000u, 0x3F800000u}, {0x3FC00000u, 0xBF800000u},
                                {0x3F810000u, 0xBF800000u}, {0x00400000u, 0x3F800000u}, {0x00000000u, 0x7F800000u}};
  const int nc = sizeof(corner) / sizeof(corner[0]);
  FILE *out = fopen(argv[4], "w");
  if (!out) {
    perror(argv[4]);
    return 1;
  }
  srand(42);
  for (int i = 0; i < count; i++) {
    uint32_t a, b;
    if (i < nc) {
      a = corner[i][0] >> sh;
      b = corner[i][1] >> sh;
    } else {
      a = ((uint32_t)rand() ^ ((uint32_t)rand() << 16)) & mask;
      b = ((uint32_t)rand() ^ ((uint32_t)rand() << 16)) & mask;
    }
    int flags = 0;
    const uint32_t r = fpref_op(op, a, b, man_w, &flags);
    fprintf(out, "%0*x%0*x%0*x%02x\n", d, a, d, b, d, r, flags & 0xFF);
  }
  fclose(out);
  printf("%s: %d %s vectors, MAN_W=%d\n", argv[4], count, op ? "add" : "mul", man_w);
  return 0;
}
