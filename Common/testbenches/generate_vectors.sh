#!/bin/bash
# Builds gen_vectors against SoftFloat and writes the bf16 vectors for fpMultiplier's and fpAdder's Vivado testbenches.
cd "$(dirname "$0")" || exit 1
ARIL=../..
SF=$ARIL/Adders/FP32/testbenches/berkeley-softfloat-3
LIB=$SF/build/Linux-x86_64-GCC/softfloat.a
[ -f $LIB ] || make -C $SF/build/Linux-x86_64-GCC || exit 1
g++ -O2 -o gen_vectors gen_vectors.cpp $LIB -I$SF/source/include || exit 1
./gen_vectors mul 7 10000 $ARIL/Multipliers/FP/testbenches/vectors_bf16.mem || exit 1
[ -d $ARIL/Adders/FP/testbenches ] && { ./gen_vectors add 7 10000 $ARIL/Adders/FP/testbenches/vectors_bf16.mem || exit 1; }
exit 0
