#!/bin/bash
# One verilator --lint-only: its messages, then '<label>: W warnings, E errors'; fails on a non-zero exit or any %Error; args: LABEL then verilator's arguments.
label=$1; shift
out=$(verilator --lint-only "$@" 2>&1); rc=$?
[ -n "$out" ] && printf '%s\n' "$out"
w=$(printf '%s\n' "$out" | command grep -c '^%Warning'); e=$(printf '%s\n' "$out" | command grep -c '^%Error')
echo "$label: $w warnings, $e errors"
[ $rc -eq 0 ] && [ $e -eq 0 ]
