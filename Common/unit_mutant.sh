#!/bin/bash
# One planted fault against a unit's own bench: copies SRC, applies SEDFILE, runs the bench command on the copy (make variables UNIT_SRC and
# BENCH_DIR appended), and passes only when the bench prints RESULT: FAILED; args: NAME SRC SEDFILE then the bench command.
name=$1 src=$2 sedf=$3; shift 3
tree=Verilator; for a in "$@"; do [ "$a" = SIM=vcs ] && tree=VCS; done  # the bench command's simulator picks the build tree
d=$(cd "$(dirname "$src")/.." && pwd)/$tree/mutant_$name
rm -rf "$d" && mkdir -p "$d" || exit 1
m="$d/$(basename "$src")"
cp "$src" "$m" && sed -i -f "$sedf" "$m" || exit 1
if cmp -s "$src" "$m"; then echo "mutant $name FAIL: the sed changed nothing"; exit 1; fi
out=$("$@" UNIT_SRC="$m" BENCH_DIR="$d/bench" 2>&1)
printf '%s\n' "$out" > "$d/run.log"
if printf '%s\n' "$out" | command grep -q "^RESULT: FAILED"; then
  echo "mutant $name caught by its bench: $(printf '%s\n' "$out" | command grep -m1 -E ' errors|\[FAIL\]' | cut -c1-150)"
  exit 0
fi
if printf '%s\n' "$out" | command grep -q "^RESULT: PASSED"; then echo "mutant $name SURVIVED its bench"; else
  echo "mutant $name SURVIVED: the bench gave no verdict"; printf '%s\n' "$out" | tail -15; fi
exit 1
