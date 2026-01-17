#!/bin/bash

# ==============================================================================
# Script Name: generate_vectors.sh
# Description: Compiles the C++ test vector generator and creates vectors.mem
# Usage: ./generate_vectors.sh
# ==============================================================================

SOFTFLOAT_DIR="./berkeley-softfloat-3"
INCLUDE_DIR="$SOFTFLOAT_DIR/source/include"
LIB_PATH="$SOFTFLOAT_DIR/build/Linux-x86_64-GCC/softfloat.a"
SOURCE_FILE="gen_vectors.cpp"
OUTPUT_BIN="gen_vectors"
OUTPUT_MEM="vectors.mem"

if [ ! -f "$LIB_PATH" ]; then
  echo "Error: SoftFloat library not found at: $LIB_PATH"
  echo "Attempting to build SoftFloat..."

  if [ -d "$SOFTFLOAT_DIR/build/Linux-x86_64-GCC" ]; then
    echo "Building SoftFloat..."
    (
      cd "$SOFTFLOAT_DIR/build/Linux-x86_64-GCC" || exit 1
      make
    )
  else
    echo "Critical Error: SoftFloat build directory missing."
    exit 1
  fi

  if [ ! -f "$LIB_PATH" ]; then
    echo "Failed to build SoftFloat. Please build it manually."
    exit 1
  fi
fi

echo "Compiling $SOURCE_FILE..."

if ! g++ -o "$OUTPUT_BIN" "$SOURCE_FILE" "$LIB_PATH" -I"$INCLUDE_DIR"; then
  echo "Error: Compilation failed!"
  exit 1
fi

echo "Executing $OUTPUT_BIN..."

if ./"$OUTPUT_BIN"; then
  echo "---------------------------------------------------------"
  echo "SUCCESS: '$OUTPUT_MEM' has been generated."
  echo "You can now run the Vivado simulation."
  echo "---------------------------------------------------------"
else
  echo "Error: Failed to generate vectors."
  exit 1
fi
