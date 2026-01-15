# Vivado DPI Linker Fix

This guide outlines how to configure Xilinx Vivado to use the host system's modern linker instead of its bundled, outdated version. This is often necessary when working with SystemVerilog DPI (Direct Programming Interface) and modern C++ standards.

## The Problem

Xilinx Vivado bundles its own version of `binutils` (including the `ld` linker) within its installation directory (`tps/lnx64`). This bundled version is often significantly older than the default system linker found on modern Linux distributions (e.g., Ubuntu 20.04/22.04, RHEL 8+).

When compiling DPI applications—especially those using C++14, C++17, or C++20—Vivado's internal `ld` often fails with:
* Symbol resolution errors.
* Incompatibilities with system `glibc` or `libstdc++`.
* Linker script syntax errors.

## The Solution

The fix involves forcing Vivado to use the host system's `/usr/bin/ld` by replacing the bundled binary with a symbolic link.

> **⚠️ Note:** This procedure modifies files inside your Vivado installation directory. Ensure you have write permissions (or use `sudo`) and follow the backup step below.

## Instructions

### 1. Identify Your Vivado Installation Path
Locate your Vivado installation. Common default paths include:
* `/tools/Xilinx/Vivado/<VERSION>`
* `/opt/Xilinx/Vivado/<VERSION>`
* `/home/<USER>/Xilinx/Vivado/<VERSION>`

### 2. Navigate to the Vivado `binutils` Directory
The linker is located deep in the `tps` (Third Party Software) directory. The specific `binutils` version folder (e.g., `binutils-2.37`) varies by Vivado release.

Run the following command, replacing `<INSTALL_PATH>` and `<VERSION>` with your actual values:

```bash
# General Syntax
cd <INSTALL_PATH>/Vivado/<VERSION>/tps/lnx64/binutils-*/bin/

# Example
# cd /tools/Xilinx/Vivado/2025.2/tps/lnx64/binutils-2.37/bin/
```

### 3. Back Up the Original Linker
Rename the existing `ld` binary to `ld.orig`. This acts as a backup, allowing you to easily revert changes if needed.

```bash
mv ld ld.bak
```

### 4. Link the System Linker
Create a symbolic link pointing from Vivado's local `ld` to your system's modern linker (`/usr/bin/ld`).

```bash
ln -s /usr/bin/ld ld
```

### 5. Verify the Change
Check that the link is valid and pointing to the correct location.

```bash
ls -l ld
```

Expected Output:
```
lrwxrwxrwx 1 user group 11 Jan 15 10:00 ld -> /usr/bin/ld
```

## ↩️ How to Revert
If you encounter unexpected issues with standard FPGA synthesis or implementation after this change, restore the original linker:

1. Navigate back to the `binutils/bin` directory.
2. Remove the symbolic link:
```bash
rm ld
```

3. Restore the backup:
```bash
mv ld.bak ld
```
