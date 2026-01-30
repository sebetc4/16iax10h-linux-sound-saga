# Fedora Kernel Patching Guide

This directory contains resources for building the Fedora kernel with the AW88399 audio patch.

## Contents

- **[FEDORA-BUILD-GUIDE.md](FEDORA-BUILD-GUIDE.md)** - Complete step-by-step guide for manually building the patched Fedora kernel with Secure Boot support
- **[automation/](automation/)** - Automated build scripts

## Quick Start

### Option 1: Automated Build (Recommended)

```bash
cd automation/scripts
./build-kernel.sh --help
./build-kernel.sh
```

The automation script handles:
- MOK signing setup for Secure Boot
- Fetching patches/firmware/UCM2 from upstream
- Cloning and configuring Fedora kernel sources
- Building kernel RPMs
- Installing and signing the kernel

### Option 2: Manual Build

Follow the [FEDORA-BUILD-GUIDE.md](FEDORA-BUILD-GUIDE.md) for detailed step-by-step instructions.

## Why Fedora Kernel?

Building the Fedora kernel (instead of vanilla) provides:

- **Secure Boot compatibility** with MOK keys
- **Native RPM packages** for clean install/uninstall
- **akmods integration** for NVIDIA and other proprietary drivers
- **Fedora patches** and optimizations included

## Requirements

- Fedora 43+ (tested on 6.18.x kernels)
- ~50GB free disk space for build
- Basic familiarity with terminal commands

## Configuration

Edit `automation/config/build.conf` to customize:
- Signing options
- Build flags
- Paths and directories

## Supported Devices

See the main [README](../README.md) for the list of compatible devices.
