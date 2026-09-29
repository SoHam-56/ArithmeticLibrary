#!/bin/bash
# Builds gen_int_vectors and writes the vectors for the integer units' Vivado testbenches (intMultiplier, intAdder, fxMac).
cd "$(dirname "$0")" || exit 1
ARIL=../..
g++ -O2 -std=c++17 -o gen_int_vectors gen_int_vectors.cpp || exit 1
[ -d $ARIL/Multipliers/Int/testbenches ] && { ./gen_int_vectors mul 10000 $ARIL/Multipliers/Int/testbenches/vectors_int8.mem || exit 1; }
[ -d $ARIL/Adders/Int/testbenches ] && { ./gen_int_vectors add 10000 $ARIL/Adders/Int/testbenches/vectors_int32.mem || exit 1; }
[ -d $ARIL/Multipliers/Fx/testbenches ] && { ./gen_int_vectors fxmac 10000 $ARIL/Multipliers/Fx/testbenches/vectors_q4_11.mem || exit 1; }
exit 0
