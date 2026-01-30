# Fedora Kernel 6.18.7 Build Guide with AW88399 Audio Patch

> **Guide version**: Fedora Kernel 6.18.7-200.fc43.x86_64
> **Compatibility**: ✅ All **6.18.x** versions are supported
> **Date**: January 2026
> **Secure Boot compatibility**: ✅ YES (manual kernel signing required – see Phase 8)

> 📌 **Note**: This guide uses kernel version **6.18.7** as an example, but the instructions apply to **all Fedora 6.18.x kernels**. Simply adjust the version numbers in the commands to match your target version.

⚠️ **IMPORTANT**: A kernel built using `fedpkg local` is **NOT** automatically signed for Secure Boot. You must manually sign the kernel with your MOK key (Phase 8) to keep Secure Boot enabled.

---

## Table of Contents

### Main Phases

1. [Introduction and benefits](#1-introduction-and-benefits)
2. [Phase 1: Installing Fedora build tools](#phase-1--installing-fedora-build-tools)
3. [Phase 2: Fetching Fedora kernel sources](#phase-2--fetching-fedora-kernel-sources)
4. [Phase 3: Preparing the audio patch](#phase-3--preparing-the-audio-patch)
5. [Phase 4: Modifying the kernel.spec file](#phase-4--modifying-the-kernelspec-file)
6. [Phase 5: Configuring audio options](#phase-5--configuring-audio-options)
7. [Phase 6: Kernel compilation](#phase-6--kernel-compilation)
8. [Phase 7: Installing the generated RPMs](#phase-7--installing-the-generated-rpms)
9. [Phase 8: Kernel signing for Secure Boot](#phase-8--kernel-signing-for-secure-boot) ⚠️ **CRITICAL if Secure Boot is enabled**
10. [Phase 9: Bootloader configuration](#phase-9--bootloader-configuration)
11. [Phase 10: NVIDIA modules and finalization](#phase-10--nvidia-modules-and-finalization) (optional – akmods builds automatically)
12. [Phase 11: Reboot and finalization](#phase-11--reboot-and-finalization)
13. [Phase 12: Archiving and cleanup](#phase-12--archiving-and-cleanup-optional) (optional)

---

## 1. Introduction and Benefits

### Why compile the Fedora kernel instead of the vanilla kernel?

**Advantages of the Fedora kernel:**

* ✅ **Secure Boot compatible**: Fedora-specific patches allow the use of custom MOK keys
* ✅ **No manual module re-signing required**: kernel modules built by Fedora are already trusted under Secure Boot
* ✅ **Native RPM packages**: clean installation and removal using `dnf`
* ✅ **Native akmods integration**: proprietary drivers (NVIDIA, etc.) work out of the box
* ✅ **Fedora patches included**: distribution-specific optimizations and fixes
* ✅ **Robust build system**: `fedpkg` for reproducible builds

> **📌 Kernel modules do NOT need to be manually re-signed** – modules built using Fedora’s kernel build system are already signed and trusted by the Fedora kernel under Secure Boot, thanks to Fedora’s lockdown and key-handling patches.

---

### Fedora Secure Boot handling: automatic MOK key integration

Unlike the vanilla kernel, the Fedora kernel includes downstream patches that automatically load **Machine Owner Keys (MOK)** from UEFI NVRAM into the kernel keyring at boot time when Secure Boot is enabled. This allows:

* ✅ Verification of kernel images signed with a user-managed MOK
* ✅ Loading of third-party modules (e.g. NVIDIA) built and signed via `akmods`
* ✅ Secure Boot to remain enabled without disabling kernel lockdown

---

### Why AW88399 support requires an out-of-tree patch

**Awinic AW88399** amplifiers used in Lenovo Legion laptops rely on a **hybrid x86 audio architecture**:

* **HDA (High Definition Audio)**: primary audio interface used by the Intel x86 audio stack
* **I²C**: control bus used to manage the AW88399 smart amplifiers

This design explains why:

1. **The driver is implemented as an HDA smart codec (scodec)**: it integrates with the HDA subsystem while controlling the amplifiers over I²C
2. **ASoC is not used**: unlike ARM/mobile platforms, Lenovo Legion systems rely on the legacy x86 HDA architecture
3. **Upstream integration is slow**: the patch has existed since mid-2024 but has not yet been merged into mainline due to review and design concerns
4. **This architecture was chosen by Lenovo**: likely to reduce BOM cost while still using modern smart amplifiers

---

### Guide Objective

Rebuild the Fedora kernel **6.18.7-200.fc43.x86_64** with the required audio patch for **Awinic AW88399** amplifiers found on:

* Lenovo Legion Pro 7i Gen 10 (16IAX10H) – Product: 83F5
* Lenovo Legion Pro 7 Gen 10 (16AFR10H) – Product: 83RU
* Lenovo Legion 5i Gen 9 (16IRX9)

---

## Phase 1: Installing Fedora Build Tools

### 1.1 ▶️ Install core tools required for kernel compilation

```bash
sudo dnf install -y \
    fedpkg \
    fedora-packager \
    rpm-build \
    rpmdevtools \
    git \
    wget \
    curl
```

> **Note**: This guide exclusively uses `fedpkg local`, which relies on `rpmbuild` for local kernel compilation.
> No chroot-based or remote build systems (`mock`, `koji`) are used in this workflow.

---

### 1.2 ▶️ Install tools required for RPM building and Secure Boot

```bash
sudo dnf install -y \
    pesign \
    sbsigntools \
    mokutil \
    grubby \
    dracut \
    ccache
```

* `pesign` is used to manually sign the kernel for Secure Boot
* `sbsigntools` is required for signing EFI binaries
* `mokutil` manages Machine Owner Keys (MOK)
* `grubby` updates bootloader entries
* `dracut` generates the initramfs
* `ccache` is optional but recommended to speed up rebuilds

---

### 1.3 ▶️ Configure pesign for Secure Boot

> **📌 Official Fedora documentation**:
> *Building a Custom Kernel – Secure Boot*
> [https://docs.fedoraproject.org/en-US/quick-docs/kernel-build-custom/](https://docs.fedoraproject.org/en-US/quick-docs/kernel-build-custom/)

```bash
# Add the current user to the pesign user list
sudo bash -c "echo $USER >> /etc/pesign/users"

# Authorize access to the pesign daemon
sudo /usr/libexec/pesign/pesign-authorize
```

This configuration allows the current user to sign kernel binaries using `pesign` **without requiring sudo for each signing operation**.

---

# Phase 2: Fetching Fedora Kernel Sources

## 2.1 ▶️ Clone the Fedora kernel repository

```bash
# Create a working directory
mkdir -p ~/fedora-kernel-build
cd ~/fedora-kernel-build

# Clone the Fedora kernel repository (all branches)
fedpkg clone -a kernel

# Enter the repository
cd kernel
```

---

## 2.2 ▶️ Select the Fedora 43 branch

```bash
# List available Fedora branches
git branch -a | grep f4

# Switch to the Fedora 43 branch
git checkout f43

# Verify
git branch
# Expected output:
# * f43
```

---

## 2.3 ▶️ Identify and check out the commit matching version 6.18.7-200

### 2.3.1 Locate the exact kernel version

```bash
git log --oneline | grep "6.18.7-200"
```

**Expected example output:**

```
7ec2a9ad5 kernel-6.18.7-200
```

> **Note**: In this case, there is no dedicated Git tag for `6.18.7-200`.
> The commit `7ec2a9ad5` corresponds exactly to this kernel release.

---

### 2.3.2 Create a local build branch from the exact commit

⚠️ **CRITICAL**: `fedpkg` does **not** work reliably in a detached HEAD state.
You **must** create a local branch from the target commit.

```bash
# Create a local build branch from the identified commit
git checkout -b build-6.18.7-audio 7ec2a9ad5
```

**Expected message:**

```
Switched to a new branch 'build-6.18.7-audio'
```

> **Why a local branch is required**
>
> * `fedpkg` refuses to operate in detached HEAD mode (`Repo in inconsistent state`)
> * A local branch allows `fedpkg local` to function normally
> * The branch name is arbitrary but descriptive
> * This branch is strictly local and must never be pushed upstream

---

### 2.3.3 Verify branch and commit state

```bash
# Verify that you are on the local branch
git branch
# Expected: * build-6.18.7-audio

# Verify the current commit
git log -1 --oneline
# Expected:
# 7ec2a9ad5 (HEAD -> build-6.18.7-audio) kernel-6.18.7-200
```

---

### 2.3.4 Verify version information in `kernel.spec`

```bash
# Check version-related macros
grep "^Version:" kernel.spec
# Expected: Version: %{specrpmversion}

grep "^%define specversion" kernel.spec
# Expected: %define specversion 6.18.7

grep "^%define pkgrelease" kernel.spec
# Expected: %define pkgrelease 200

grep "^Release:" kernel.spec
# Expected: Release: %{specrpmrelease}%{?buildid}%{?dist}
```

---

## 2.4 ▶️ Download kernel source archives

```bash
# Download all source archives declared in the spec file
fedpkg sources

# Verify downloaded archives
ls -lh *.tar.xz
ls -lh patch-*.patch
```

**Typical result for kernel 6.18.7:**

```
linux-6.18.7.tar.xz                    ~150M
kernel-abi-stablelists-6.18.7.tar.xz   ~3K
kernel-kabi-dw-6.18.7.tar.xz           ~1K
patch-6.18-redhat.patch                ~60K
```

---

## 2.5 ▶️ Install build dependencies

```bash
# Install all build dependencies required by kernel.spec
sudo dnf builddep kernel.spec
```

This command installs all required compilers, build tools, and development libraries by resolving dependencies declared in `kernel.spec`.

---

## 2.6 ▶️ Inspect patches declared in `kernel.spec`

```bash
# List patches declared in the spec file
grep "^Patch" kernel.spec
```

**Expected output for Fedora kernel 6.18.7:**

```
Patch1: patch-6.18-redhat.patch
Patch999999: linux-kernel-test.patch
```

```bash
# Count Patch declarations
grep -c "^Patch" kernel.spec
# Expected: 2
```

> Although only a small number of patches are declared,
> `patch-6.18-redhat.patch` is a **consolidated downstream patch** containing many individual changes.

```bash
# Inspect the approximate number of modifications inside the consolidated patch
grep -c "^diff --git" patch-6.18-redhat.patch
# Expected: several dozen changes (exact number may vary between minor releases)
```

---

# Phase 3: Preparing the Audio Patch

## 3.1 ▶️ Retrieve the AW88399 audio patch

```bash
# Return to the parent working directory
cd ~/fedora-kernel-build

# Clone the audio fix repository
git clone https://github.com/nadimkobeissi/16iax10h-linux-sound-saga.git

# Copy the patch targeting Linux 6.18
cp 16iax10h-linux-sound-saga/fix/patches/16iax10h-audio-linux-6.18.patch kernel/
```

---

## 3.2 ▶️ Install the required firmware

The patch requires the firmware file `aw88399_acf.bin` to be present at runtime.

```bash
# Check whether the firmware is already installed
ls -la /lib/firmware/aw88399_acf.bin
```

If the file is missing:

```bash
# Install the firmware manually
sudo cp ~/fedora-kernel-build/16iax10h-linux-sound-saga/fix/firmware/aw88399_acf.bin /lib/firmware/

# Set correct permissions
sudo chmod 644 /lib/firmware/aw88399_acf.bin

# Verify
ls -la /lib/firmware/aw88399_acf.bin
```

> **Note**: Firmware files are not signed and do not affect Secure Boot.
> They are loaded by the kernel at runtime by the driver.

---

# Phase 4: Modifying the `kernel.spec` File

## 4.1 📚 Understanding the structure of `kernel.spec`

The `kernel.spec` file is the core of the RPM build process. It defines:

* Kernel versions and releases
* The list of patches to apply
* Configuration options
* Build instructions
* Generated RPM packages

---

## 4.2 ▶️ Back up the original spec file

```bash
cd ~/fedora-kernel-build/kernel
cp kernel.spec kernel.spec.orig
```

---

## 4.3 📚 Understanding Fedora’s patch system (Important!)

Fedora now uses a **consolidated patch system**:

```bash
# List patches declared in the spec file
grep "^Patch" kernel.spec
# Typical output for kernel 6.18.7:
# Patch1: patch-6.18-redhat.patch      ← Fedora consolidated MEGA-PATCH
# Patch999999: linux-kernel-test.patch ← Test patch (optional)
```

**Explanation:**

* **Patch1** (`patch-6.18-redhat.patch`) contains **ALL Fedora downstream patches**, consolidated into a single file
* For kernel 6.18.7, this patch contains ~44 individual changes (~51 KB)
* The newer the kernel, the fewer differences there are compared to upstream

```bash
# Verify the consolidated patch
ls -lh patch-6.18-redhat.patch
# Expected: ~51K (for 6.18.7)
# Count the number of modifications it contains
grep -c "^diff --git" patch-6.18-redhat.patch
# Expected: ~43 modifications
```

**Important**: Your audio patch must be added **after** the Fedora consolidated patch, using a high patch number to avoid conflicts.

---

## 4.4 ▶️ Adding the patch to `kernel.spec`

You must make **three changes** to `kernel.spec`:

1. **Declare the patch** (Patch section)
2. **Apply the patch** (`%prep` section)
3. **Define a build ID** to identify your custom build

Two methods are available.

---

### 🚀 Method A: Automated script (recommended)

Create and run the following script **as-is**:

```bash
cd ~/fedora-kernel-build/kernel
cat > modify_kernel_spec.sh << 'EOF'
#!/bin/bash
SPEC_FILE="kernel.spec"
PATCH_FILE="16iax10h-audio-linux-6.18.patch"
BUILD_ID=".audio"
# Backup
cp "$SPEC_FILE" "${SPEC_FILE}.orig"
echo "✓ Backup created: ${SPEC_FILE}.orig"
# 1. Add patch declaration (after Patch999999)
PATCH_LINE=$(grep -n "^Patch999999:" "$SPEC_FILE" | cut -d: -f1)
sed -i "${PATCH_LINE}a Patch10000: ${PATCH_FILE}" "$SPEC_FILE"
echo "✓ Patch declared: Patch10000: ${PATCH_FILE}"
# 2. Add patch application (after linux-kernel-test.patch)
APPLY_LINE=$(grep -n "ApplyOptionalPatch linux-kernel-test.patch" "$SPEC_FILE" | cut -d: -f1)
sed -i "${APPLY_LINE}a ApplyOptionalPatch ${PATCH_FILE}" "$SPEC_FILE"
echo "✓ Patch application added"
# 3. Set buildid
sed -i "s/^# define buildid .local$/%define buildid ${BUILD_ID}/" "$SPEC_FILE"
echo "✓ BuildID set: ${BUILD_ID}"
# Verification
echo ""
echo "=== Verification ==="
echo "Declared patches:"
grep "^Patch" "$SPEC_FILE" | tail -3
echo ""
echo "BuildID:"
grep "define buildid" "$SPEC_FILE" | grep -v "^#"
echo ""
echo "Applied patches:"
grep "ApplyOptionalPatch" "$SPEC_FILE" | grep -v "ApplyOptionalPatch()" | tail -3
EOF

chmod +x modify_kernel_spec.sh

./modify_kernel_spec.sh
```

---

### ✏️ Method B: Manual modification

If you prefer to edit the file manually, apply the following three changes.

**1. Declare the patch** (search for `Patch999999:`)

```bash
nano kernel.spec
# Search (Ctrl+W): Patch999999
# Add after this line:
Patch10000: 16iax10h-audio-linux-6.18.patch
```

**2. Apply the patch** (search for `ApplyOptionalPatch linux-kernel-test.patch`)

```bash
# Search (Ctrl+W): ApplyOptionalPatch linux-kernel-test.patch
# Add after this line:
ApplyOptionalPatch 16iax10h-audio-linux-6.18.patch
```

**3. Define the build ID** (search for `# define buildid`)

```bash
# Search (Ctrl+W): # define buildid
# Replace the line:
# define buildid .local
# With:
%define buildid .audio
```

---

## 4.5 ✅ Verifying the modifications

Regardless of the method used, verify that everything is correct:

```bash
cd ~/fedora-kernel-build/kernel
echo "=== 1. Declared patches ==="
grep "^Patch" kernel.spec | tail -3
echo -e "\n=== 2. BuildID ==="
grep "define buildid" kernel.spec | grep -v "^#"
echo -e "\n=== 3. Applied patches ==="
grep "ApplyOptionalPatch" kernel.spec | grep -v "ApplyOptionalPatch()" | tail -3
echo -e "\n=== 4. Patch file present ==="
ls -lh 16iax10h-audio-linux-6.18.patch
```

**Expected result:**

```
Patch10000: 16iax10h-audio-linux-6.18.patch
%define buildid .audio
ApplyOptionalPatch 16iax10h-audio-linux-6.18.patch
```

✅ If these entries are present, you can proceed to the next phase.

---

# Phase 5: Configuring Audio Options

## 5.1 📚 Why this step is required

The **patch** added the **source code** for AW88399 support.
However, this code will only be compiled if the corresponding **kernel configuration options** are explicitly enabled.

Fedora’s kernel build system requires **all new configuration symbols introduced by a patch** to be defined in **all architecture config files** (x86_64, aarch64, ppc64le, etc.), otherwise the build fails.

---

## 5.2 ✅ Detecting required configuration options

First, create a script to detect which options are already present and which must be added:

```bash
cd ~/fedora-kernel-build/kernel

# Create the detection script
cat > check-audio-options.sh << 'EOF'
#!/bin/bash

echo "=========================================="
echo "  Detecting required audio options"
echo "=========================================="
echo ""

# Options required by the audio patch
REQUIRED_OPTIONS=(
  "CONFIG_SND_HDA_SCODEC_AW88399"
  "CONFIG_SND_HDA_SCODEC_AW88399_I2C"
  "CONFIG_SND_SOC_AW88399"
  "CONFIG_SND_SOC_SOF_INTEL_TOPLEVEL"
  "CONFIG_SND_SOC_SOF_INTEL_COMMON"
  "CONFIG_SND_SOC_SOF_INTEL_MTL"
  "CONFIG_SND_SOC_SOF_INTEL_LNL"
)

CONFIG_FILE="kernel-x86_64-fedora.config"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "❌ Error: $CONFIG_FILE not found"
  echo "   Are you in the correct directory?"
  exit 1
fi

echo "📋 Analyzing file: $CONFIG_FILE"
echo ""

# Check each option
missing_options=()
present_options=()

for option in "${REQUIRED_OPTIONS[@]}"; do
  if grep -q "^${option}=" "$CONFIG_FILE" 2>/dev/null; then
    value=$(grep "^${option}=" "$CONFIG_FILE" | cut -d= -f2)
    echo "✅ $option=$value (already present)"
    present_options+=("$option")
  elif grep -q "^# ${option} is not set" "$CONFIG_FILE" 2>/dev/null; then
    echo "⚠️  $option (disabled, will be enabled)"
    missing_options+=("$option")
  else
    echo "❌ $option (missing, will be added)"
    missing_options+=("$option")
  fi
done

echo ""
echo "=========================================="
echo "📊 Summary:"
echo "   ✅ Options already present: ${#present_options[@]}"
echo "   ⚠️  Options to add: ${#missing_options[@]}"
echo "=========================================="

if [ ${#missing_options[@]} -gt 0 ]; then
  echo ""
  echo "Options that will be added:"
  for opt in "${missing_options[@]}"; do
    echo "   - $opt"
  done
fi

echo ""
EOF

chmod +x check-audio-options.sh

# Run the detection
./check-audio-options.sh
```

**Expected result for Fedora 43 kernel 6.18.7:**

```
📊 Summary:
   ✅ Options already present: 2
   ⚠️  Options to add: 5

Options that will be added:
   - CONFIG_SND_HDA_SCODEC_AW88399
   - CONFIG_SND_HDA_SCODEC_AW88399_I2C
   - CONFIG_SND_SOC_SOF_INTEL_COMMON
   - CONFIG_SND_SOC_SOF_INTEL_MTL
   - CONFIG_SND_SOC_SOF_INTEL_LNL
```

---

## 5.3 ▶️ Back up all configuration files

⚠️ **IMPORTANT**: Always back up configuration files before modifying them.

```bash
cd ~/fedora-kernel-build/kernel

# Create backup directory
mkdir -p ~/fedora-kernel-build/config-backups

# Copy ALL configuration files
cp kernel-*.config ~/fedora-kernel-build/config-backups/

# Verify
echo "✅ Backups created in ~/fedora-kernel-build/config-backups/"
ls -1 ~/fedora-kernel-build/config-backups/ | wc -l
echo "files backed up"
```

**To restore in case of problems:**

```bash
cp ~/fedora-kernel-build/config-backups/kernel-*.config ~/fedora-kernel-build/kernel/
```

---

## 5.4 ▶️ Robust script to add audio options

This script:

1. Removes duplicates
2. Ensures options are added only once
3. Enables options on x86_64
4. Disables them on other architectures

```bash
cd ~/fedora-kernel-build/kernel

# Create the robust addition script
cat > add-audio-config.sh << 'EOF'
#!/bin/bash

echo "=========================================="
echo "  Adding audio options (ROBUST)"
echo "=========================================="
echo ""

# Options to add
OPTIONS_TO_ADD=(
  "CONFIG_SND_HDA_SCODEC_AW88399"
  "CONFIG_SND_HDA_SCODEC_AW88399_I2C"
  "CONFIG_SND_SOC_SOF_INTEL_COMMON"
  "CONFIG_SND_SOC_SOF_INTEL_MTL"
  "CONFIG_SND_SOC_SOF_INTEL_LNL"
)

# Function to clean duplicates in a file
clean_duplicates() {
  local config_file="$1"
  # Use awk to remove duplicates while keeping first occurrence
  awk '!seen[$0]++' "$config_file" > "${config_file}.tmp"
  mv "${config_file}.tmp" "$config_file"
}

# Function to remove all occurrences of an option
remove_option() {
  local config_file="$1"
  local option="$2"
  sed -i "/^${option}=/d" "$config_file"
  sed -i "/^# ${option} is not set/d" "$config_file"
}

# STEP 1: Clean existing duplicates
echo "=== STEP 1: Cleaning existing duplicates ==="
for config in kernel-*.config; do
  clean_duplicates "$config"
  echo "✅ $config"
done
echo ""

# STEP 2: Remove old occurrences of audio options
echo "=== STEP 2: Removing old occurrences ==="
for config in kernel-*.config; do
  for option in "${OPTIONS_TO_ADD[@]}"; do
    remove_option "$config" "$option"
  done
  echo "✅ $config"
done
echo ""

# STEP 3: Add options on x86_64 (enabled)
echo "=== STEP 3: Adding to x86_64 (enabled =m) ==="
x86_count=0
for config in kernel-x86_64*-fedora.config kernel-x86_64*-rhel.config; do
  cat >> "$config" << 'AUDIOCFG'

# Audio fix for Awinic AW88399 (Legion Pro 7i Gen 10)
CONFIG_SND_HDA_SCODEC_AW88399=m
CONFIG_SND_HDA_SCODEC_AW88399_I2C=m
CONFIG_SND_SOC_SOF_INTEL_COMMON=m
CONFIG_SND_SOC_SOF_INTEL_MTL=m
CONFIG_SND_SOC_SOF_INTEL_LNL=m
AUDIOCFG
  echo "✅ $config"
  ((x86_count++))
done
echo "📊 Total: $x86_count x86_64 files modified"
echo ""

# STEP 4: Add on other architectures (disabled)
echo "=== STEP 4: Adding to other architectures (disabled) ==="
other_count=0
for config in kernel-*-fedora.config kernel-*-rhel.config; do
  # Skip x86_64
  if [[ "$config" == kernel-x86_64* ]]; then
    continue
  fi

  cat >> "$config" << 'AUDIOCFG'

# Audio fix for Awinic AW88399 (Legion Pro 7i Gen 10)
# CONFIG_SND_HDA_SCODEC_AW88399 is not set
# CONFIG_SND_HDA_SCODEC_AW88399_I2C is not set
# CONFIG_SND_SOC_SOF_INTEL_COMMON is not set
# CONFIG_SND_SOC_SOF_INTEL_MTL is not set
# CONFIG_SND_SOC_SOF_INTEL_LNL is not set
AUDIOCFG
  echo "✅ $config"
  ((other_count++))
done
echo "📊 Total: $other_count other architecture files modified"
echo ""

# STEP 5: Final verification
echo "=== STEP 5: Anti-duplicate verification ==="
error_found=0

for config in kernel-*.config; do
  for option in "${OPTIONS_TO_ADD[@]}"; do
    # Use grep with word boundary to avoid false positives
    # (CONFIG_SND_HDA_SCODEC_AW88399_I2C should not match CONFIG_SND_HDA_SCODEC_AW88399)
    count=$(grep -E -c "^${option}=|^# ${option} is not set" "$config" 2>/dev/null || echo 0)
    if [ "$count" -gt 1 ]; then
      echo "❌ ERROR: $config contains $count occurrences of $option (duplicate!)"
      error_found=1
    fi
  done
done

if [ $error_found -eq 0 ]; then
  echo "✅ No duplicates detected"
else
  echo ""
  echo "❌ Duplicates were detected!"
  echo "   Re-run this script to clean up."
  exit 1
fi

echo ""
echo "=========================================="
echo "✅ Configuration completed successfully!"
echo "=========================================="
echo ""
EOF

chmod +x add-audio-config.sh

# Run the script
./add-audio-config.sh
```

**Expected result:**

```
==========================================
✅ Configuration completed successfully!
==========================================

📊 Total: 8 x86_64 files modified
📊 Total: 31 other architecture files modified
✅ No duplicates detected
```

---

## 5.5 ✅ Final verification of added options

```bash
cd ~/fedora-kernel-build/kernel

echo "=== Verifying x86_64-fedora.config ==="
grep "CONFIG_SND_HDA_SCODEC_AW88399\|CONFIG_SND_SOC_SOF_INTEL" kernel-x86_64-fedora.config | grep -v SOUNDWIRE | grep -v TOPLEVEL

echo ""
echo "=== Verifying aarch64-fedora.config ==="
grep "CONFIG_SND_HDA_SCODEC_AW88399\|CONFIG_SND_SOC_SOF_INTEL" kernel-aarch64-fedora.config | grep -v SOUNDWIRE | grep -v TOPLEVEL

echo ""
echo "=== Counting occurrences (should be = 2 everywhere) ==="
echo "x86_64-fedora.config:"
grep -c "CONFIG_SND_HDA_SCODEC_AW88399" kernel-x86_64-fedora.config

echo "aarch64-fedora.config:"
grep -c "CONFIG_SND_HDA_SCODEC_AW88399" kernel-aarch64-fedora.config
```

**Expected result:**

```
=== Verifying x86_64-fedora.config ===
CONFIG_SND_HDA_SCODEC_AW88399=m
CONFIG_SND_HDA_SCODEC_AW88399_I2C=m
CONFIG_SND_SOC_SOF_INTEL_COMMON=m
CONFIG_SND_SOC_SOF_INTEL_MTL=m
CONFIG_SND_SOC_SOF_INTEL_LNL=m

=== Verifying aarch64-fedora.config ===
# CONFIG_SND_HDA_SCODEC_AW88399 is not set
# CONFIG_SND_HDA_SCODEC_AW88399_I2C is not set
# CONFIG_SND_SOC_SOF_INTEL_COMMON is not set
# CONFIG_SND_SOC_SOF_INTEL_MTL is not set
# CONFIG_SND_SOC_SOF_INTEL_LNL is not set

=== Counting occurrences (should be = 2 everywhere) ===
x86_64-fedora.config: 2
aarch64-fedora.config: 2
```

---

## 5.6 ✅ Validation test with `fedpkg prep`

Before launching the full compilation, validate the configuration:

```bash
cd ~/fedora-kernel-build/kernel
fedpkg --release f43 prep
```

If successful, no errors such as:

* `Found unset config items`
* `reassigning to symbol`

will appear.

---

## 5.7 📋 Summary

| Step | Script                   | Purpose                         |
| ---: | ------------------------ | ------------------------------- |
|  5.2 | `check-audio-options.sh` | Detects missing/present options |
|  5.3 | Manual commands          | Configuration backup            |
|  5.4 | `add-audio-config.sh`    | Robust option insertion         |
|  5.5 | Manual checks            | Verification                    |
|  5.6 | `fedpkg prep`            | Final validation                |

**Added options (5 total):**

* `CONFIG_SND_HDA_SCODEC_AW88399`
* `CONFIG_SND_HDA_SCODEC_AW88399_I2C`
* `CONFIG_SND_SOC_SOF_INTEL_COMMON`
* `CONFIG_SND_SOC_SOF_INTEL_MTL`
* `CONFIG_SND_SOC_SOF_INTEL_LNL`

✅ You are now ready for **Phase 6: Kernel Compilation**.

---

## Phase 6: Kernel Compilation

### 6.1 ▶️ Local compilation with `fedpkg local`

For a local build:

```bash
cd ~/fedora-kernel-build/kernel

# Start the compilation
# --release f43 : REQUIRED because we are working on a local branch
# --without selftests : skip kernel selftests (saves time)
# --without debug : do not build the separate kernel-debug package (saves time)
fedpkg --release f43 local -- --without selftests --without debug
```

#### Why `--release f43`?

* A local branch `build-6.18.x-audio` was created earlier (Phase 2)
* `fedpkg` cannot infer the Fedora release from a non-standard branch name
* `--release f43` explicitly tells `fedpkg` to target Fedora 43

---

#### 💡 Difference between `--without debug` and `--without debuginfo`

**`--without debug`** (✅ Recommended):

* Prevents building the **separate `kernel-debug` package**
* Does **NOT** affect the main kernel
* Saves both build time and disk space
* **No functional downside**

**`--without debuginfo`** (⚠️ Use only if disk space is limited):

* Disables `CONFIG_DEBUG_INFO_BTF` in the main kernel
* Impacts advanced features:

  * Advanced eBPF tools (bpftrace, some BCC tools)
  * BTF-based kernel tracing
  * Some advanced systemd features
* The kernel will **boot and run normally** for standard usage

✅ **Recommendation**: Always use `--without debug`.
Only add `--without debuginfo` if disk space is critically limited and advanced tracing/eBPF is not required.

⏱️ **Estimated build time**: 1 to 5 hours depending on CPU performance

---

## Phase 7: Installing the Generated RPMs

### 7.1 ▶️ Configure kernel retention (recommended)

Before installing the custom kernel, configure how many kernels Fedora should keep automatically:

```bash
sudo nano /etc/dnf/dnf.conf
installonly_limit=5
```

**Recommended values**:

* `2` → minimal disk usage
* `3` → Fedora default
* `5` → **Recommended for patched kernels**

💡 Setting this *before* installation prevents Fedora from removing your custom kernel during future system updates.

---

### 7.2 ✅ Verify generated packages

```bash
cd ~/fedora-kernel-build/kernel/x86_64
ls -lh kernel-6.18.7-200.audio.fc43.x86_64.rpm \
       kernel-core-6.18.7-200.audio.fc43.x86_64.rpm \
       kernel-modules-6.18.7-200.audio.fc43.x86_64.rpm \
       kernel-modules-core-6.18.7-200.audio.fc43.x86_64.rpm \
       kernel-modules-extra-6.18.7-200.audio.fc43.x86_64.rpm \
       kernel-devel-6.18.7-200.audio.fc43.x86_64.rpm
```

> **Note**: `kernel-devel` is generated by the build but is **not installed automatically by Fedora**. It is required only for building external kernel modules.

---

### 7.3 ▶️ Install kernel packages (standard installation – recommended)

```bash
sudo dnf install -y \
  kernel-6.18.7-200.audio.fc43.x86_64.rpm \
  kernel-core-6.18.7-200.audio.fc43.x86_64.rpm \
  kernel-modules-6.18.7-200.audio.fc43.x86_64.rpm \
  kernel-modules-core-6.18.7-200.audio.fc43.x86_64.rpm \
  kernel-modules-extra-6.18.7-200.audio.fc43.x86_64.rpm \
  kernel-devel-6.18.7-200.audio.fc43.x86_64.rpm
```

---

### 7.4 ▶️ Alternative: Minimal installation

```bash
sudo dnf install -y \
  kernel-6.18.7-200.audio.fc43.x86_64.rpm \
  kernel-core-6.18.7-200.audio.fc43.x86_64.rpm \
  kernel-modules-6.18.7-200.audio.fc43.x86_64.rpm \
  kernel-modules-core-6.18.7-200.audio.fc43.x86_64.rpm
```

---

### 7.5 ✅ Installation verification

```bash
rpm -qa | grep "kernel.*6.18.7.*audio"
ls -la /boot/*6.18.7*audio*
ls /lib/modules/ | grep audio
```

---

## Phase 8: Kernel Signing for Secure Boot

> ⚠️ **THIS PHASE IS MANDATORY IF SECURE BOOT IS ENABLED**

---

### 8.1 ✅ Prerequisite: Existing MOK key

You must already have a Machine Owner Key (MOK) created and enrolled.

Verify that the key exists:

```bash
ls -la /var/lib/shim-signed/mok/MOK.{priv,der,pem}
```

Verify that the key is enrolled in UEFI:

```bash
mokutil --list-enrolled | grep -A5 "Subject:"
```

---

#### If you do not have a MOK key yet

Create and enroll one:

```bash
# Create directory
sudo mkdir -p /var/lib/shim-signed/mok

# Generate private key and certificate
sudo openssl req -new -x509 -newkey rsa:2048 \
    -keyout /var/lib/shim-signed/mok/MOK.priv \
    -outform DER -out /var/lib/shim-signed/mok/MOK.der \
    -days 36500 -subj "/CN=My Kernel Signing Key/" -nodes

# Convert to PEM format (useful for some tools)
sudo openssl x509 -inform DER \
    -in /var/lib/shim-signed/mok/MOK.der \
    -out /var/lib/shim-signed/mok/MOK.pem

# Enroll the key (requires reboot)
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
```

You will be prompted to define a temporary password.

⚠️ **Important**: Reboot and complete the enrollment in **MokManager** during boot.

```bash
sudo reboot
```

---

### 8.2 ▶️ Sign the kernel using `pesign` (Fedora-native method)

`pesign` is the standard Fedora / Red Hat signing tool.
It relies on an NSS (Network Security Services) database to store certificates and private keys.

> **Note**: All commands are executed with `sudo` for simplicity and consistency, even though `pesign` can be configured for non-root usage.

---

#### Step 1: Create a PKCS#12 bundle (private key + certificate)

```bash
sudo openssl pkcs12 -export \
    -out /tmp/MOK.p12 \
    -inkey /var/lib/shim-signed/mok/MOK.priv \
    -in /var/lib/shim-signed/mok/MOK.pem \
    -name "MOK Signing Key"
```

Press **Enter twice** for an empty password, or set one if preferred.

---

#### Step 2: Import the PKCS#12 bundle into pesign’s NSS database

```bash
# Remove existing entry if present
sudo certutil -d /etc/pki/pesign -D -n "MOK Signing Key" 2>/dev/null || true

# Import PKCS#12 (includes private key)
sudo pk12util -d /etc/pki/pesign -i /tmp/MOK.p12

# Remove temporary file
sudo rm /tmp/MOK.p12
```

---

#### Step 3: Verify key import

```bash
# List certificates
sudo certutil -d /etc/pki/pesign -L
```

Expected output:

* `MOK Signing Key` with trust flags `u,u,u`

Verify that the **private key** is present:

```bash
sudo certutil -d /etc/pki/pesign -K
```

---

#### Step 4: Sign the kernel image

```bash
# Backup the unsigned kernel
sudo cp /boot/vmlinuz-6.18.7-200.audio.fc43.x86_64 \
        /boot/vmlinuz-6.18.7-200.audio.fc43.x86_64.unsigned

# Sign the kernel
sudo pesign -n /etc/pki/pesign -c "MOK Signing Key" \
    -i /boot/vmlinuz-6.18.7-200.audio.fc43.x86_64 \
    -o /boot/vmlinuz-6.18.7-200.audio.fc43.x86_64.signed \
    -s

# Verify signed file exists
ls -lh /boot/vmlinuz-6.18.7-200.audio.fc43.x86_64.signed
```

---

#### Step 5: Replace the kernel and regenerate GRUB

```bash
sudo mv /boot/vmlinuz-6.18.7-200.audio.fc43.x86_64.signed \
        /boot/vmlinuz-6.18.7-200.audio.fc43.x86_64
```

Regenerate GRUB configuration:

```bash
sudo grub2-mkconfig -o /boot/grub2/grub.cfg
```

---

> 💡 **Important note about multiple signatures**
>
> After signing, the kernel **may contain multiple signatures**:
>
> 1. **Red Hat Test Certificate**
>    – May be added automatically during Fedora builds
>    – Ignored by UEFI Secure Boot
>
> 2. **Your MOK signature**
>    – The signature actually validated by Secure Boot
>
> This is **normal and expected**.
> UEFI only requires **one trusted signature** to be present.

---

### 8.3 ✅ Verify kernel signature

#### Verify with `sbverify`

```bash
sudo sbverify --list /boot/vmlinuz-6.18.7-200.audio.fc43.x86_64
```

Expected output:

```
signature 1
  Red Hat Test Certificate (may be present)

signature 2
  Subject: CN=My Kernel Signing Key
```

---

#### Verify that the MOK key is enrolled in UEFI

```bash
mokutil --list-enrolled
mokutil --list-enrolled | grep -A5 "Subject:"
```

---

## Phase 9: Bootloader Configuration

### 9.1 ✅ Fedora uses BLS (Boot Loader Specification)

Fedora uses **BLS entries** located in:

```
/boot/loader/entries/
```

```bash
# List existing BLS entries
ls -la /boot/loader/entries/

# The RPM installation should have created an entry automatically
ls /boot/loader/entries/*6.18.7*audio*
```

---

### 9.2 ✅ Verify the generated BLS entry

```bash
cat /boot/loader/entries/*6.18.7*audio*.conf
```

Expected content:

```conf
title Fedora Linux (6.18.7-200.audio.fc43.x86_64) 43 (Workstation Edition)
version 6.18.7-200.audio.fc43.x86_64
linux /vmlinuz-6.18.7-200.audio.fc43.x86_64
initrd /initramfs-6.18.7-200.audio.fc43.x86_64.img
options root=UUID=xxxxx-xxxxx ro rhgb quiet
grub_users $grub_users
grub_arg --unrestricted
grub_class fedora
```

> ⚠️ **Do NOT edit this file manually**
> Fedora manages BLS entries automatically.

---

### 9.3 ✅ Verify audio-related boot parameters (SOF)

> **Important**
> The following kernel parameter is **commonly present** on Intel SOF platforms,
> but **must always be verified**:

```
snd_intel_dspcfg.dsp_driver=3
```

Check the current kernel entry:

```bash
sudo grubby --info=/boot/vmlinuz-6.18.7-200.audio.fc43.x86_64
```

If the parameter is present, **no action is required**.

> ℹ️ If the parameter is missing (rare on modern Intel systems), it must be added
> using `grubby --update-kernel`.
> **Do not edit BLS files directly.**

---

### 9.4 ▶️ Set the default kernel (optional)

```bash
# Check the current default kernel
sudo grubby --default-kernel

# Set the audio kernel as default
sudo grubby --set-default=/boot/vmlinuz-6.18.7-200.audio.fc43.x86_64

# Verify the change
sudo grubby --default-kernel
```

---

## Phase 10: NVIDIA Modules and Finalization

### 10.0 📚 Understanding how akmods works

> ✅ **Good news: akmods rebuilds automatically**
>
> The `akmods.service` detects new kernels at boot and rebuilds NVIDIA modules
> automatically if required.

This phase is **optional** if you are willing to:

* wait ~2–3 minutes on first boot
* see a temporary black screen during module compilation

---

### 10.1 ▶️ Option A: Let akmods rebuild at boot (simplest)

```bash
# Verify akmods is enabled
systemctl is-enabled akmods.service

# Reboot — akmods will rebuild automatically
sudo reboot
```

---

### 10.2 ▶️ Option B: Build NVIDIA modules manually before reboot (recommended)

```bash
# Force module rebuild for the new kernel
sudo akmods --force --kernels 6.18.7-200.audio.fc43.x86_64
```

Wait until the build completes.

```bash
# Modules must be present and compressed
ls -la /lib/modules/6.18.7-200.audio.fc43.x86_64/extra/nvidia/
```

Expected modules:

```
nvidia.ko.xz
nvidia-drm.ko.xz
nvidia-modeset.ko.xz
nvidia-uvm.ko.xz
nvidia-peermem.ko.xz
```

---

### 🔐 Secure Boot and NVIDIA modules

With Secure Boot enabled:

* akmods **automatically signs** the modules
* **only if**:

  * akmods keys exist in `/var/lib/akmods/keys/`
  * and those keys are **enrolled in MOK**

```bash
# Verify akmods keys
ls -la /var/lib/akmods/keys/

# Check if they are enrolled
mokutil --list-enrolled | grep akmods
```

If the keys are not enrolled:

```bash
sudo mokutil --import /var/lib/akmods/keys/akmods.der
# Reboot and confirm enrollment in MokManager
```

If you manually ran `akmods --force`, update module dependencies:

```bash
sudo depmod -a 6.18.7-200.audio.fc43.x86_64
```

> ℹ️ This step is automatic when akmods runs at boot.

---

### 10.3 ✅ Final verification before reboot

```bash
echo "=== Full verification ==="

echo -e "\n1. Signed kernel:"
sudo pesign -S -i /boot/vmlinuz-6.18.7-200.audio.fc43.x86_64 | grep "common name"

echo -e "\n2. NVIDIA modules present:"
ls /lib/modules/6.18.7-200.audio.fc43.x86_64/extra/nvidia/

echo -e "\n3. modules.dep correctness:"
grep "extra/nvidia/nvidia.ko" \
  /lib/modules/6.18.7-200.audio.fc43.x86_64/modules.dep | head -1

echo -e "\n4. initramfs timestamp:"
ls -lh /boot/initramfs-6.18.7-200.audio.fc43.x86_64.img

echo -e "\n5. Enrolled MOK keys:"
mokutil --list-enrolled | grep "CN="
```

Expected state:

* Kernel signed with your MOK key
* NVIDIA modules present and compressed (`.ko.xz`)
* `modules.dep` references `.ko.xz` (not `.ko`)
* Recent initramfs (generated automatically by RPM install)
* Your MOK key and akmods key are enrolled

---

## Phase 11: Reboot and Finalization

### 11.1 ▶️ Pre-reboot preparation (UCM2 file deployment)

**Before rebooting**, the UCM2 audio configuration files must be installed:

```bash
# Backup original UCM2 files
sudo cp /usr/share/alsa/ucm2/HDA/HiFi-analog.conf \
    /usr/share/alsa/ucm2/HDA/HiFi-analog.conf.orig
sudo cp /usr/share/alsa/ucm2/HDA/HiFi-mic.conf \
    /usr/share/alsa/ucm2/HDA/HiFi-mic.conf.orig

# Deploy custom UCM2 files for AW88399
sudo cp -f ~/fedora-kernel-build/16iax10h-linux-sound-saga/fix/ucm2/HiFi-analog.conf \
    /usr/share/alsa/ucm2/HDA/HiFi-analog.conf
sudo cp -f ~/fedora-kernel-build/16iax10h-linux-sound-saga/fix/ucm2/HiFi-mic.conf \
    /usr/share/alsa/ucm2/HDA/HiFi-mic.conf
```

> ℹ️ These files define the ALSA UCM2 routing required for the AW88399 amplifier.

---

### 11.2 ▶️ Reboot into the new kernel

```bash
# Final check of the default kernel
sudo grubby --default-kernel
# Expected: /boot/vmlinuz-6.18.7-200.audio.fc43.x86_64

# Reboot
sudo reboot
```

> ⏳ **During reboot**
> If Secure Boot is enabled and your MOK key has not yet been enrolled,
> the **MOK Manager** screen will appear. Follow the on-screen instructions
> to enroll the key.

---

### 11.3 ✅ Post-boot verification

**After reboot**, verify that the system is running correctly:

```bash
# Confirm the running kernel
uname -r
# Expected: 6.18.7-200.audio.fc43.x86_64

# Verify Secure Boot state
mokutil --sb-state
# Expected: SecureBoot enabled

# List loaded kernel modules
lsmod | grep -E "nvidia|snd_hda|snd_sof"
```

---

### 11.4 ▶️ Post-boot audio configuration (FIRST installation only)

> ⚠️ **This section is REQUIRED ONLY for the FIRST installation**
> of the AW88399 audio fix.

If you already have a working patched kernel with audio properly configured,
**skip this section**.

For a first-time installation, initialize the audio stack:

```bash
# Reload UCM2 configuration
alsaucm -c hw:0 reset
alsaucm -c hw:0 reload

# Calibrate volumes (set to 100% to avoid software attenuation)
amixer sset -c 0 'Master' 100%
amixer sset -c 0 'Speaker' 100%
amixer sset -c 0 'Headphone' 100%

# Display ALSA mixer controls
amixer -c 0 contents | head -50
```

> ℹ️ Volume calibration is required once to ensure correct gain staging
> with the AW88399 amplifier.

---

### 11.5 ✅ Audio tests

```bash
# List detected audio devices
aplay -l
# Expected: "HDA Intel PCH" card with device "hw:0,0"

# Confirm SOF (Sound Open Firmware) is active
cat /sys/module/snd_intel_dspcfg/parameters/dsp_driver
# Expected: 3 (SOF enabled)

# Verify AW88399 driver loading
dmesg | grep -i aw88399
# Expected: driver and firmware loading messages

# Confirm firmware loading
dmesg | grep -i "aw88399_acf.bin"
# Expected: "aw88399_acf.bin loaded successfully"

# Audio playback test
speaker-test -c 2 -t wav
# You should hear "Front Left" / "Front Right" alternately
```

---

### 11.6 ✅ NVIDIA tests (if applicable)

```bash
# Test NVIDIA driver
nvidia-smi
# Should display GPU information

# Display NVIDIA driver version
cat /proc/driver/nvidia/version
# Expected: installed driver version (e.g. 565.57.01)

# Confirm NVIDIA kernel modules are loaded
lsmod | grep nvidia
```

---

### 11.7 ✅ Error log review

Verify that no critical errors occurred:

```bash
# Display boot-time errors
journalctl -b -p err

# Search for audio-related errors
journalctl -b | grep -i -E "snd|alsa|audio|sof|aw88399"

# Search for NVIDIA-related errors
journalctl -b | grep -i nvidia
```

> ✅ **If everything is correct**
> Audio should be functional, Secure Boot should remain enabled,
> and the system is ready for cleanup or daily use.

---

## Phase 12: Archiving and Cleanup (Optional)

### 12.1 ▶️ Archive essential RPMs

> **⚠️ Important**: Always back up the RPMs **before** cleaning up.

```bash
# Create archive directory
mkdir -p ~/fedora-kernel-build/archive

# Copy RPMs (includes kernel-devel in case it is needed later)
cd ~/fedora-kernel-build/kernel/x86_64
cp kernel-6.18.7-200.audio.fc43.x86_64.rpm \
   kernel-core-6.18.7-200.audio.fc43.x86_64.rpm \
   kernel-modules-6.18.7-200.audio.fc43.x86_64.rpm \
   kernel-modules-core-6.18.7-200.audio.fc43.x86_64.rpm \
   kernel-modules-extra-6.18.7-200.audio.fc43.x86_64.rpm \
   kernel-devel-6.18.7-200.audio.fc43.x86_64.rpm \
   ~/fedora-kernel-build/archive/
```

---

### 12.2 ▶️ Compress the archive

```bash
# Compress the archive
cd ~/fedora-kernel-build
tar -czf kernel-6.18.7-200.audio.fc43-rpms.tar.gz archive/

# Verify the archive
ls -lh kernel-6.18.7-200.audio.fc43-rpms.tar.gz
tar -tzf kernel-6.18.7-200.audio.fc43-rpms.tar.gz
```

---

### 12.3 ▶️ Move the archive and clean up

```bash
# Move the archive to a permanent location (adjust path as needed)
mkdir -p ~/kernel-archives
mv kernel-6.18.7-200.audio.fc43-rpms.tar.gz ~/kernel-archives/

# Optional: completely remove the build directory
rm -rf ~/fedora-kernel-build/
```

---

### 12.4 ▶️ Restore RPMs from the archive

If you need to reinstall the kernel later:

```bash
# Extract the archive
cd ~/Documents/kernel-archives
tar -xzf kernel-6.18.7-200.audio.fc43-rpms.tar.gz
cd archive

# Reinstall the packages
sudo dnf install -y kernel-6.18.7-200.audio.fc43.x86_64.rpm \
                    kernel-core-6.18.7-200.audio.fc43.x86_64.rpm \
                    kernel-modules-6.18.7-200.audio.fc43.x86_64.rpm \
                    kernel-modules-core-6.18.7-200.audio.fc43.x86_64.rpm \
                    kernel-modules-extra-6.18.7-200.audio.fc43.x86_64.rpm
```

> ℹ️ `kernel-devel` is usually not required at runtime unless you need to rebuild external modules.

---

### 12.5 ✅ Manage installed kernels

> **💡 Note**: If you followed [Phase 7.1](#71--configure-kernel-retention-recommended), kernel retention is already configured.

**Verify and clean up old kernels**:

```bash
# Check current install-only configuration
grep installonly_limit /etc/dnf/dnf.conf

# List installed kernels
rpm -qa | grep ^kernel-core | sort

# Remove old kernels automatically (optional)
sudo dnf remove --oldinstallonly --setopt installonly_limit=2 kernel

# Or remove a specific kernel manually
sudo dnf remove kernel-6.17.x-xxx.fc43.x86_64
```

> **⚠️ Important**
> Always keep **at least two kernels** installed so you can boot a known-good
> kernel if the patched one fails.