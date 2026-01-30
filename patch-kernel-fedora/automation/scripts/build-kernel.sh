#!/bin/bash
#
# Automated Fedora Kernel Build Script with AW88399 Audio Patch
# ==============================================================
#
# This script automates the entire process of:
# 1. Setting up MOK signing for Secure Boot (with reboot support)
# 2. Fetching patches/firmware/UCM2 from upstream repository
# 3. Cloning Fedora kernel repository
# 4. Selecting desired kernel version
# 5. Applying AW88399 audio patch
# 6. Configuring audio kernel options
# 7. Building kernel RPMs
# 8. Installing kernel RPMs
# 9. Signing kernel for Secure Boot
#
# Usage:
#   ./build-kernel.sh [options]
#
# Options:
#   -c, --config FILE      Use custom config file (default: ../config/build.conf)
#   -v, --version VER      Build specific kernel version (skip interactive selection)
#   --skip-setup           Skip setup phase (assume environment is ready)
#   --skip-cleanup         Skip cleanup phase after build
#   --cleanup-only         Only run cleanup (archive and remove build dirs)
#   --install-firmware     Only install firmware and UCM2 files
#   --post-install         Run post-install audio configuration
#   --setup-mok            Only setup MOK signing (create keys, enroll, configure pesign)
#   --check                Quick check of system status (no modifications)
#   --no-sign              Build without signing (ignore ENABLE_SIGNING setting)
#   -h, --help             Show this help message
#

set -euo pipefail

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default config file
CONFIG_FILE="${PROJECT_ROOT}/config/build.conf"

# Control flags
SKIP_SETUP=false
SKIP_CLEANUP=false
CLEANUP_ONLY=false
INSTALL_FIRMWARE_ONLY=false
POST_INSTALL_ONLY=false
SETUP_MOK_ONLY=false
CHECK_ONLY=false
NO_SIGN=false

# Cleanup handler for unexpected exits
cleanup_on_exit() {
    local exit_code=$?
    if ((exit_code != 0 && exit_code != 130)); then
        echo ""
        echo "[ERROR] Script failed with exit code: $exit_code" >&2
        if [[ -n "${LOG_FILE:-}" ]]; then
            echo "[ERROR] Check log file: $LOG_FILE" >&2
        fi
        if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
            echo "[INFO] Partial build may remain at: $WORK_DIR" >&2
        fi
    fi
}
trap cleanup_on_exit EXIT

# Handle Ctrl+C gracefully
trap 'echo ""; echo "Interrupted by user. Exiting..."; exit 130' INT TERM

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: --config requires a file path" >&2
                exit 1
            fi
            CONFIG_FILE="$2"
            shift 2
            ;;
        -v|--version)
            if [[ -z "${2:-}" ]]; then
                echo "ERROR: --version requires a version string" >&2
                exit 1
            fi
            KERNEL_VERSION="$2"
            shift 2
            ;;
        --skip-setup)
            SKIP_SETUP=true
            shift
            ;;
        --skip-cleanup)
            SKIP_CLEANUP=true
            shift
            ;;
        --cleanup-only)
            CLEANUP_ONLY=true
            shift
            ;;
        --install-firmware)
            INSTALL_FIRMWARE_ONLY=true
            shift
            ;;
        --post-install)
            POST_INSTALL_ONLY=true
            shift
            ;;
        --setup-mok)
            SETUP_MOK_ONLY=true
            shift
            ;;
        --check)
            CHECK_ONLY=true
            shift
            ;;
        --no-sign)
            NO_SIGN=true
            shift
            ;;
        -h|--help)
            grep "^#" "$0" | grep -v "^#!/" | sed 's/^# //' | sed 's/^#//'
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# Load configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Override signing if --no-sign specified
if [[ "$NO_SIGN" == true ]]; then
    ENABLE_SIGNING=false
fi

# Load library functions (order matters - logging first)
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=lib/config-validator.sh
source "${SCRIPT_DIR}/lib/config-validator.sh"
# shellcheck source=lib/version-detection.sh
source "${SCRIPT_DIR}/lib/version-detection.sh"
# shellcheck source=lib/patch-manager.sh
source "${SCRIPT_DIR}/lib/patch-manager.sh"
# shellcheck source=lib/mok-manager.sh
source "${SCRIPT_DIR}/lib/mok-manager.sh"
# shellcheck source=lib/signing.sh
source "${SCRIPT_DIR}/lib/signing.sh"
# shellcheck source=lib/resources.sh
source "${SCRIPT_DIR}/lib/resources.sh"
# shellcheck source=lib/setup.sh
source "${SCRIPT_DIR}/lib/setup.sh"
# shellcheck source=lib/cleanup.sh
source "${SCRIPT_DIR}/lib/cleanup.sh"

# Validate and apply configuration defaults
validate_and_prepare_config || {
    echo "ERROR: Configuration validation failed" >&2
    exit 1
}

# Initialize logging
init_logging "$LOG_DIR"

log_section "Automated Kernel Build - AW88399 Audio Patch"
log_info "Configuration: $CONFIG_FILE"
log_info "Work directory: $WORK_DIR"

# ============================================================================
# MODE: Quick Check
# ============================================================================

if [[ "$CHECK_ONLY" == true ]]; then
    quick_setup_check
    exit 0
fi

# ============================================================================
# MODE: MOK Setup Only
# ============================================================================

if [[ "$SETUP_MOK_ONLY" == true ]]; then
    interactive_signing_setup
    exit $?
fi

# ============================================================================
# MODE: Post-Install Audio Configuration
# ============================================================================

if [[ "$POST_INSTALL_ONLY" == true ]]; then
    log_section "Post-Install Audio Configuration"

    log_info "This configures audio after first boot with the patched kernel"
    echo ""

    # Check if we're running on patched kernel
    CURRENT_KERNEL=$(uname -r)
    if [[ "$CURRENT_KERNEL" == *"audio"* ]]; then
        log_success "Running on patched kernel: $CURRENT_KERNEL"
    else
        log_warn "Not running on patched kernel: $CURRENT_KERNEL"
        log_info "Make sure to boot into the patched kernel first"
    fi

    # Reload UCM2 configuration
    log_step 1 "Reloading UCM2 configuration"
    if command -v alsaucm &>/dev/null; then
        alsaucm -c hw:0 reset 2>/dev/null || true
        alsaucm -c hw:0 reload 2>/dev/null || true
        log_success "UCM2 configuration reloaded"
    else
        log_warn "alsaucm not found"
    fi

    # Set volume levels
    log_step 2 "Setting volume levels (100% for optimal quality)"
    if command -v amixer &>/dev/null; then
        amixer sset -c 0 'Master' 100% 2>/dev/null || true
        amixer sset -c 0 'Speaker' 100% 2>/dev/null || true
        amixer sset -c 0 'Headphone' 100% 2>/dev/null || true
        log_success "Volume levels configured"
    else
        log_warn "amixer not found"
    fi

    # Show ALSA controls
    log_step 3 "Current ALSA controls"
    if command -v amixer &>/dev/null; then
        echo ""
        amixer -c 0 contents 2>/dev/null | head -30 || true
        echo ""
    fi

    # Verify audio devices
    log_step 4 "Verifying audio devices"
    if command -v aplay &>/dev/null; then
        echo ""
        aplay -l 2>/dev/null || true
        echo ""
    fi

    # Check driver status
    log_step 5 "Checking AW88399 driver status"
    echo ""
    dmesg | grep -i aw88399 | tail -10 || log_info "No AW88399 messages in dmesg"
    echo ""

    # Check firmware
    log_step 6 "Checking firmware status"
    dmesg | grep -i "aw88399_acf.bin" | tail -5 || log_info "No firmware messages in dmesg"
    echo ""

    echo "=============================================="
    echo "  Post-Install Configuration Complete!"
    echo "=============================================="
    echo ""
    echo "Test audio with:"
    echo "  speaker-test -c 2 -t wav"
    echo ""
    echo "If audio doesn't work, try:"
    echo "  systemctl --user restart pipewire pipewire-pulse wireplumber"
    echo "=============================================="
    echo ""

    exit 0
fi

# ============================================================================
# MODE: Firmware Installation Only
# ============================================================================

if [[ "$INSTALL_FIRMWARE_ONLY" == true ]]; then
    log_section "Firmware Installation Mode"
    log_info "Installing firmware and UCM2 files"

    # Fetch resources from upstream
    if ! fetch_all_resources; then
        log_error "Failed to fetch resources from upstream"
        exit 1
    fi

    # Install firmware
    if ! install_firmware; then
        log_error "Failed to install firmware"
        exit 1
    fi

    # Install UCM2
    if ! install_ucm2; then
        log_warn "Failed to install UCM2 (may need manual setup)"
    fi

    # Reload ALSA
    log_step 3 "Reloading ALSA configuration"
    if command -v alsaucm &>/dev/null; then
        alsaucm -c hw:0 reset 2>/dev/null || true
        alsaucm -c hw:0 reload 2>/dev/null || true
        log_success "ALSA configuration reloaded"
    else
        log_info "alsaucm not found, skip ALSA reload"
    fi

    echo ""
    echo "=============================================="
    echo "  Firmware Installation Complete!"
    echo "=============================================="
    echo ""
    echo "Next steps:"
    echo "  1. Restart audio services:"
    echo "     systemctl --user restart pipewire pipewire-pulse wireplumber"
    echo ""
    echo "  2. Or reboot for changes to take full effect"
    echo "=============================================="
    echo ""

    exit 0
fi

# ============================================================================
# MODE: Cleanup Only
# ============================================================================

if [[ "$CLEANUP_ONLY" == true ]]; then
    log_info "Cleanup-only mode: Archiving RPMs and removing build directories"

    if [[ -d "${WORK_DIR}/kernel/x86_64" ]]; then
        BUILT_KERNEL_VERSION=$(ls "${WORK_DIR}/kernel/x86_64/kernel-[0-9]"*.rpm 2>/dev/null \
            | head -1 \
            | grep -oP 'kernel-\K[0-9]+\.[0-9]+\.[0-9]+-[0-9]+\.[^.]+\.fc[0-9]+\.x86_64' || echo "")

        if [[ -n "$BUILT_KERNEL_VERSION" ]]; then
            log_info "Detected built kernel: $BUILT_KERNEL_VERSION"
            run_cleanup "$BUILT_KERNEL_VERSION"
            log_success "Cleanup completed!"
            exit 0
        else
            log_error "No kernel RPMs found in ${WORK_DIR}/kernel/x86_64"
            exit 1
        fi
    else
        log_error "Build directory not found: ${WORK_DIR}/kernel/x86_64"
        log_info "Nothing to clean up"
        exit 0
    fi
fi

# ============================================================================
# PHASE 0: Setup and Environment Preparation
# ============================================================================

if [[ "$SKIP_SETUP" == false ]]; then
    run_setup || error_exit "Setup phase failed"
else
    log_info "Skipping setup phase (--skip-setup specified)"
fi

# ============================================================================
# PHASE 1: Pre-requisites and Detection
# ============================================================================

log_section "Phase 1: Pre-requisites"

# Detect Fedora version
if [[ -z "${FEDORA_RELEASE:-}" ]]; then
    FEDORA_RELEASE=$(detect_fedora_release) || error_exit "Failed to detect Fedora release"
    log_info "Auto-detected Fedora release: $FEDORA_RELEASE"
else
    log_info "Using configured Fedora release: $FEDORA_RELEASE"
fi

# Extract numeric Fedora version
FEDORA_VERSION=$(echo "$FEDORA_RELEASE" | grep -oP '\d+')

# Check required tools
log_step "1.1" "Checking required tools"
if ! check_required_tools; then
    error_exit "Missing required tools"
fi
log_success "All required tools present"

# ============================================================================
# PHASE 2: Kernel Source Preparation
# ============================================================================

log_section "Phase 2: Kernel Source Preparation"

mkdir -p "$WORK_DIR"
KERNEL_DIR="${WORK_DIR}/kernel"

log_step "2.1" "Setting up Fedora kernel repository"

if [[ -d "$KERNEL_DIR" ]]; then
    log_info "Kernel directory exists, updating..."
    cd "$KERNEL_DIR"
    git fetch --all || log_warn "Failed to fetch updates"
else
    log_info "Cloning Fedora kernel repository (this may take a while)..."
    cd "$WORK_DIR"
    fedpkg clone -a kernel || error_exit "Failed to clone kernel repository"
    cd kernel
fi

log_success "Kernel repository ready: $KERNEL_DIR"

# Checkout Fedora branch
log_step "2.2" "Checking out Fedora ${FEDORA_RELEASE} branch"
git checkout "$FEDORA_RELEASE" || error_exit "Failed to checkout branch $FEDORA_RELEASE"
log_success "Branch $FEDORA_RELEASE checked out"

# ============================================================================
# PHASE 3: Version Selection
# ============================================================================

log_section "Phase 3: Kernel Version Selection"

if [[ -n "${KERNEL_VERSION:-}" ]]; then
    log_info "Using specified version: $KERNEL_VERSION"
    SELECTED_VERSION="$KERNEL_VERSION"
else
    log_step "3.1" "Detecting available kernel versions"
    AVAILABLE_VERSIONS=$(list_available_kernel_versions "$KERNEL_DIR" "$MAX_VERSIONS_PER_MAJOR")

    if [[ -z "$AVAILABLE_VERSIONS" ]]; then
        error_exit "No kernel versions found"
    fi

    VERSION_COUNT=$(echo "$AVAILABLE_VERSIONS" | wc -l)
    log_success "Found $VERSION_COUNT versions"

    # Interactive selection
    SELECTED_VERSION=$(select_kernel_version "$AVAILABLE_VERSIONS" 20)
    if [[ -z "$SELECTED_VERSION" ]]; then
        error_exit "No version selected"
    fi
fi

log_success "Selected version: kernel-$SELECTED_VERSION"

# Get the right patch for this version
log_step "3.2" "Selecting patch for kernel $SELECTED_VERSION"

# Extract major.minor for patch selection
KERNEL_MAJOR_MINOR=$(echo "$SELECTED_VERSION" | grep -oP '^\d+\.\d+')

AUDIO_PATCH=$(get_patch_file "$KERNEL_MAJOR_MINOR") || error_exit "No patch available for kernel $KERNEL_MAJOR_MINOR"
log_success "Using patch: $(basename "$AUDIO_PATCH")"

# Find commit for selected version
log_step "3.3" "Finding commit for kernel-$SELECTED_VERSION"
COMMIT_HASH=$(find_commit_for_version "$KERNEL_DIR" "$SELECTED_VERSION")
log_success "Commit found: $COMMIT_HASH"

# Create build branch
BUILD_BRANCH="build-${SELECTED_VERSION}-audio"
log_step "3.4" "Creating build branch: $BUILD_BRANCH"

git branch -D "$BUILD_BRANCH" 2>/dev/null || true
git checkout -b "$BUILD_BRANCH" "$COMMIT_HASH" || error_exit "Failed to create build branch"
log_success "Build branch created: $BUILD_BRANCH"

# ============================================================================
# PHASE 4: Download Sources
# ============================================================================

log_section "Phase 4: Downloading Kernel Sources"

log_step "4.1" "Downloading source archives"
fedpkg sources || error_exit "Failed to download sources"

if ! ls ./*.tar.xz &>/dev/null; then
    error_exit "Source tarball not found"
fi
log_success "Sources downloaded"

log_step "4.2" "Installing build dependencies"
log_info "This may require sudo password..."

if sudo dnf builddep -y kernel.spec; then
    log_success "Build dependencies installed"
else
    log_warn "Failed to install some dependencies (may already be installed)"
fi

# ============================================================================
# PHASE 5: Apply Audio Patch
# ============================================================================

log_section "Phase 5: Applying Audio Patch"

copy_patch_to_kernel "$AUDIO_PATCH" "$KERNEL_DIR" || error_exit "Failed to copy patch"
modify_kernel_spec "${KERNEL_DIR}/kernel.spec" "$AUDIO_PATCH" "$BUILD_ID" || \
    error_exit "Failed to modify kernel.spec"

# ============================================================================
# PHASE 6: Configure Audio Options
# ============================================================================

log_section "Phase 6: Audio Kernel Configuration"

log_step "6.1" "Creating audio configuration scripts"

cat > "${KERNEL_DIR}/check-audio-options.sh" << 'CHECKEOF'
#!/bin/bash
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
for option in "${REQUIRED_OPTIONS[@]}"; do
  if grep -q "^${option}=" "$CONFIG_FILE" 2>/dev/null; then
    echo "  $option"
  else
    echo "  $option (missing)"
  fi
done
CHECKEOF

chmod +x "${KERNEL_DIR}/check-audio-options.sh"

cat > "${KERNEL_DIR}/add-audio-config.sh" << 'ADDEOF'
#!/bin/bash
set -e

OPTIONS_TO_ADD=(
  "CONFIG_SND_HDA_SCODEC_AW88399"
  "CONFIG_SND_HDA_SCODEC_AW88399_I2C"
  "CONFIG_SND_SOC_SOF_INTEL_COMMON"
  "CONFIG_SND_SOC_SOF_INTEL_MTL"
  "CONFIG_SND_SOC_SOF_INTEL_LNL"
)

clean_duplicates() {
  awk '!seen[$0]++' "$1" > "$1.tmp"
  mv "$1.tmp" "$1"
}

remove_option() {
  sed -i "/^${2}=/d" "$1"
  sed -i "/^# ${2} is not set/d" "$1"
}

for config in kernel-*.config; do
  clean_duplicates "$config"
  for option in "${OPTIONS_TO_ADD[@]}"; do
    remove_option "$config" "$option"
  done
done

for config in kernel-x86_64*-fedora.config kernel-x86_64*-rhel.config; do
  [ -f "$config" ] || continue
  cat >> "$config" << 'AUDIOCFG'

# Audio fix for Awinic AW88399
CONFIG_SND_HDA_SCODEC_AW88399=m
CONFIG_SND_HDA_SCODEC_AW88399_I2C=m
CONFIG_SND_SOC_SOF_INTEL_COMMON=m
CONFIG_SND_SOC_SOF_INTEL_MTL=m
CONFIG_SND_SOC_SOF_INTEL_LNL=m
AUDIOCFG
done

for config in kernel-*-fedora.config kernel-*-rhel.config; do
  [[ "$config" == kernel-x86_64* ]] && continue
  [ -f "$config" ] || continue
  cat >> "$config" << 'AUDIOCFG'

# Audio fix for Awinic AW88399
# CONFIG_SND_HDA_SCODEC_AW88399 is not set
# CONFIG_SND_HDA_SCODEC_AW88399_I2C is not set
# CONFIG_SND_SOC_SOF_INTEL_COMMON is not set
# CONFIG_SND_SOC_SOF_INTEL_MTL is not set
# CONFIG_SND_SOC_SOF_INTEL_LNL is not set
AUDIOCFG
done

echo "Audio configuration added"
ADDEOF

chmod +x "${KERNEL_DIR}/add-audio-config.sh"

log_success "Configuration scripts created"

log_step "6.2" "Applying audio configuration"
cd "$KERNEL_DIR"
./add-audio-config.sh || error_exit "Failed to add audio configuration"

log_step "6.3" "Verifying audio configuration"
./check-audio-options.sh

log_step "6.4" "Testing configuration with fedpkg prep"
rm -rf kernel-*-build/ 2>/dev/null || true

# Helper function to run fedpkg prep with workaround for "fg: no job control" error
run_fedpkg_prep() {
    local release="$1"
    local max_attempts=2
    local attempt=1

    while ((attempt <= max_attempts)); do
        log_debug "Attempt $attempt/$max_attempts: running fedpkg prep"

        # Capture output and error
        local prep_output
        local prep_exitcode

        if prep_output=$(fedpkg --release "$release" prep 2>&1); then
            log_debug "fedpkg prep succeeded"
            return 0
        else
            prep_exitcode=$?

            # Check if this is the "fg: no job control" error
            if echo "$prep_output" | grep -q "fg: no job control"; then
                log_warn "Detected 'fg: no job control' error (known RPM macro bug)"

                if ((attempt < max_attempts)); then
                    log_info "Applying workaround: updating python-rpm-macros..."

                    # Try to update the problematic packages
                    if sudo dnf update -y python3-devel python-rpm-macros rpm-build 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
                        log_success "Packages updated, retrying fedpkg prep..."
                        ((attempt++))
                        continue
                    else
                        log_warn "Package update failed, but continuing..."
                    fi
                fi
            fi

            # If we get here, either it's not the fg error, or we've exhausted attempts
            log_error "fedpkg prep failed after $attempt attempt(s)"
            echo "$prep_output" | tee -a "${LOG_FILE:-/dev/null}"
            return $prep_exitcode
        fi
    done

    return 1
}

run_fedpkg_prep "$FEDORA_RELEASE" || error_exit "fedpkg prep failed - check configuration"
log_success "Configuration validated"

# ============================================================================
# PHASE 7: Build Kernel
# ============================================================================

log_section "Phase 7: Building Kernel"

log_info "This will take 1-5 hours depending on your machine..."
log_info "Compilation started at: $(date '+%Y-%m-%d %H:%M:%S')"

# Build fedpkg options array
build_fedpkg_options() {
    local opts=()
    [[ "${BUILD_WITHOUT_SELFTESTS:-true}" == true ]] && opts+=(--without selftests)
    [[ "${BUILD_WITHOUT_DEBUG:-true}" == true ]] && opts+=(--without debug)
    [[ "${BUILD_WITHOUT_DEBUGINFO:-false}" == true ]] && opts+=(--without debuginfo)
    echo "${opts[*]}"
}

BUILD_OPTIONS=$(build_fedpkg_options)
log_info "Build options: $BUILD_OPTIONS"

BUILD_START=$(date +%s)

# shellcheck disable=SC2086
if fedpkg --release "$FEDORA_RELEASE" local $BUILD_OPTIONS; then
    BUILD_END=$(date +%s)
    BUILD_DURATION=$((BUILD_END - BUILD_START))
    BUILD_DURATION_MIN=$((BUILD_DURATION / 60))

    log_success "Kernel build completed in ${BUILD_DURATION_MIN} minutes"
else
    error_exit "Kernel build failed"
fi

log_step "7.1" "Verifying generated RPMs"
RPM_DIR="${KERNEL_DIR}/x86_64"

if [[ ! -d "$RPM_DIR" ]]; then
    error_exit "RPM directory not found: $RPM_DIR"
fi

RPM_COUNT=$(find "$RPM_DIR" -name "*.rpm" -type f 2>/dev/null | wc -l)
if ((RPM_COUNT == 0)); then
    error_exit "No RPMs generated"
fi

log_success "Found $RPM_COUNT RPM packages"

echo ""
echo "=== Generated RPMs ==="
ls -lh "$RPM_DIR"/*.rpm | head -20
echo ""

# ============================================================================
# PHASE 8: Install Kernel RPMs
# ============================================================================

log_section "Phase 8: Installing Kernel RPMs"

KERNEL_RPM=$(find "$RPM_DIR" -name "kernel-[0-9]*.rpm" -type f \
    | grep -v "kernel-core\|kernel-modules\|kernel-devel\|kernel-headers" \
    | head -n1)

if [[ -z "$KERNEL_RPM" ]]; then
    error_exit "No kernel RPM found"
fi

KERNEL_VERSION_FULL=$(basename "$KERNEL_RPM" .rpm | sed 's/^kernel-//')

log_info "Installing kernel version: $KERNEL_VERSION_FULL"

RPMS_TO_INSTALL=(
    "kernel-${KERNEL_VERSION_FULL}.rpm"
    "kernel-core-${KERNEL_VERSION_FULL}.rpm"
    "kernel-modules-${KERNEL_VERSION_FULL}.rpm"
    "kernel-modules-core-${KERNEL_VERSION_FULL}.rpm"
    "kernel-modules-extra-${KERNEL_VERSION_FULL}.rpm"
    "kernel-devel-${KERNEL_VERSION_FULL}.rpm"
)

log_step "8.1" "Installing kernel RPMs"
cd "$RPM_DIR"

INSTALL_LIST=()
for rpm in "${RPMS_TO_INSTALL[@]}"; do
    if [[ -f "$rpm" ]]; then
        INSTALL_LIST+=("$rpm")
        log_debug "Will install: $rpm"
    fi
done

if ((${#INSTALL_LIST[@]} == 0)); then
    error_exit "No RPMs found to install"
fi

if sudo dnf install -y "${INSTALL_LIST[@]}"; then
    log_success "Kernel RPMs installed successfully"
else
    error_exit "Failed to install kernel RPMs"
fi

log_step "8.2" "Verifying kernel installation"

VMLINUZ_PATH="/boot/vmlinuz-${KERNEL_VERSION_FULL}"
if [[ -f "$VMLINUZ_PATH" ]]; then
    log_success "Kernel installed: $VMLINUZ_PATH"
else
    error_exit "Kernel not found at $VMLINUZ_PATH after installation"
fi

MODULES_PATH="/lib/modules/${KERNEL_VERSION_FULL}"
if [[ -d "$MODULES_PATH" ]]; then
    log_success "Modules installed: $MODULES_PATH"
else
    log_warn "Modules directory not found: $MODULES_PATH"
fi

# ============================================================================
# PHASE 9: Install Firmware and UCM2
# ============================================================================

log_section "Phase 9: Installing Firmware and UCM2"

install_firmware || log_warn "Firmware installation failed"
install_ucm2 || log_warn "UCM2 installation failed"

# ============================================================================
# PHASE 10: Kernel Signing
# ============================================================================

if [[ "${ENABLE_SIGNING:-true}" == true ]]; then
    log_section "Phase 10: Kernel Signing"

    if check_signing_prerequisites; then
        log_info "Signing prerequisites verified"

        if [[ -f "$VMLINUZ_PATH" ]]; then
            sign_kernel_pesign "$VMLINUZ_PATH" "${MOK_CERT_NAME:-MOK Signing Key}" || \
                log_warn "Kernel signing failed (kernel will boot but Secure Boot may fail)"
        else
            log_warn "Kernel not found at $VMLINUZ_PATH, skipping signing"
        fi
    else
        log_warn "Signing prerequisites not met, skipping signing"
        log_info "Run '$0 --setup-mok' to configure signing"
    fi
else
    log_info "Kernel signing disabled (ENABLE_SIGNING=false or --no-sign)"
fi

# ============================================================================
# PHASE 11: Cleanup and Archive
# ============================================================================

if [[ "$SKIP_CLEANUP" == false ]]; then
    log_section "Phase 11: Cleanup and Archive"

    BUILT_KERNEL_VERSION="${KERNEL_VERSION_FULL}"
    if run_cleanup "$BUILT_KERNEL_VERSION"; then
        log_success "Cleanup completed"
    else
        log_warn "Cleanup failed or was cancelled"
        log_info "Build directories preserved at: $WORK_DIR"
    fi
else
    log_info "Skipping cleanup phase (--skip-cleanup specified)"
    log_info "Build artifacts preserved at: $WORK_DIR"
fi

# ============================================================================
# BUILD COMPLETE
# ============================================================================

echo ""
echo -e "${GREEN}==============================================${NC}"
echo -e "${GREEN}  Kernel Build Successful!${NC}"
echo -e "${GREEN}==============================================${NC}"
echo ""
echo -e "Kernel version: ${GREEN}${KERNEL_VERSION_FULL}${NC}"

# Set as default kernel if configured
DEFAULT_KERNEL_SET=false
if [[ "${SET_DEFAULT_KERNEL:-false}" == true ]]; then
    log_info "Setting new kernel as default..."
    if sudo grubby --set-default="/boot/vmlinuz-${KERNEL_VERSION_FULL}"; then
        DEFAULT_KERNEL_SET=true
    fi
fi

if [[ "$DEFAULT_KERNEL_SET" == true ]]; then
    echo -e "Default:        ${GREEN}Yes${NC}"
else
    echo -e "Default:        ${YELLOW}No${NC}"
fi

echo -e "Log file:       ${BLUE}$LOG_FILE${NC}"

if [[ "${ENABLE_SIGNING:-true}" == true ]] && check_signing_prerequisites &>/dev/null; then
    echo -e "Signing:        ${GREEN}Enabled${NC} (Secure Boot ready)"
else
    echo -e "Signing:        ${YELLOW}Disabled${NC} (manual signing may be needed)"
fi

echo ""
echo -e "${BLUE}Next steps:${NC}"

if [[ "$DEFAULT_KERNEL_SET" != true ]]; then
    echo "  Set as default kernel:"
    echo -e "     ${YELLOW}sudo grubby --set-default=/boot/vmlinuz-${KERNEL_VERSION_FULL}${NC}"
    echo ""
fi

echo "  Reboot and select new kernel:"
echo -e "     ${YELLOW}sudo reboot${NC}"
echo ""
echo "  After first boot, run post-install configuration:"
echo -e "     ${YELLOW}$0 --post-install${NC}"
echo ""
echo "  Verify audio:"
echo -e "     ${YELLOW}dmesg | grep -i aw88399${NC}"
echo -e "     ${YELLOW}aplay -l${NC}"
echo ""
echo -e "${GREEN}==============================================${NC}"
echo ""

log_info "Build completed successfully at $(date '+%Y-%m-%d %H:%M:%S')"
