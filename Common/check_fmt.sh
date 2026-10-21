#!/bin/bash
# check-fmt: no RTL outside the allowlist reads a precision (FMT_, EXP_W, MAN_W, EXPONENT_WIDTH, MANTISSA_WIDTH, is_int, is_fp32, from_fp32, widen( ); args: ROOT ALLOW_ERE (paths relative to ROOT).
root=${1:?usage: check_fmt.sh ROOT ALLOW_ERE}; allow=${2:-'^$'}
pat='FMT_|EXP_W|MAN_W|EXPONENT_WIDTH|MANTISSA_WIDTH|is_int|is_fp32|from_fp32|widen\('
n=0; bad=0
while IFS= read -r f; do
  rel=${f#"$root"/}
  printf '%s\n' "$rel" | /usr/bin/grep -q -E "$allow" && continue
  n=$((n + 1))
  hits=$(/usr/bin/grep -n -E "$pat" "$f")
  if [ -n "$hits" ]; then
    bad=$((bad + 1))
    printf '%s\n' "$hits" | sed "s|^|check-fmt: $rel:|"
  fi
done < <(/usr/bin/find "$root" \( -name .git -o -name testbenches -o -name 'Verilator*' -o -name results \) -prune -o \( -name '*.sv' -o -name '*.svh' -o -name '*.v' \) -type f -print | /usr/bin/sort)
echo "check-fmt: $n RTL files outside the allowlist, $bad naming a precision"
[ "$n" -gt 0 ] && [ "$bad" -eq 0 ]
