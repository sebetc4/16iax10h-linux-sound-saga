#!/bin/bash
# Setup Library for Kernel Build Environment
# Handles dependency installation, resource fetching, and MOK verification

# ============================================================================
# System Checks
# ============================================================================

# Check if running on Fedora
check_fedora() {
    if [[ ! -f /etc/fedora-release ]]; then
        log_error "This script must run on Fedora"
        return 1
    fi

    local fedora_version
    fedora_version=$(rpm -E %fedora)
    log_info "Fedora $fedora_version detected"
    return 0
}

# Check for required disk space
check_disk_space() {
    local work_dir="${WORK_DIR:-$HOME/fedora-kernel-build}"
    local parent_dir
    parent_dir=$(dirname "$work_dir")
    local required_gb=50

    log_info "Checking available disk space..."

    local available_gb
    available_gb=$(df -BG "$parent_dir" 2>/dev/null | awk 'NR==2 {print int($4)}')

    if [[ -z "$available_gb" ]]; then
        log_warn "Could not determine available disk space"
        return 0
    fi

    if ((available_gb < required_gb)); then
        log_warn "Low disk space: ${available_gb}GB available, ${required_gb}GB recommended"
        echo ""
        echo -n "Continue anyway? [y/N]: "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            return 1
        fi
    else
        log_success "Disk space OK: ${available_gb}GB available"
    fi

    return 0
}

# ============================================================================
# Dependency Installation
# ============================================================================

# Upgrade critical RPM build packages to avoid known bugs
upgrade_rpm_build_packages() {
    log_info "Upgrading RPM build packages (required for correct operation)..."

    # These packages must be up-to-date to avoid bugs like "fg: no job control"
    # which occurs with older versions of python-rpm-macros
    local critical_packages=(
        python-rpm-macros
        python3-rpm-macros
        rpm-build
    )

    if sudo dnf upgrade -y "${critical_packages[@]}" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_success "RPM build packages up-to-date"
    else
        log_warn "Could not upgrade some RPM packages (may already be latest)"
    fi
}

# Install required packages
install_build_dependencies() {
    log_section "Installing Build Dependencies"

    # First, upgrade critical RPM packages to avoid known bugs
    upgrade_rpm_build_packages

    local required_packages=(
        # Fedora build tools
        fedpkg
        fedora-packager
        rpm-build
        koji
        # General tools
        git
        wget
        curl
        # Signing tools
        pesign
        sbsigntools
        mokutil
        openssl
        nss-tools
        # Boot tools
        grubby
        dracut
        # Build optimization
        ccache
    )

    # Alternative package names for different Fedora versions
    declare -A package_alternatives=(
        ["wget"]="wget2-wget"
    )

    log_info "Checking required packages..."

    local missing_packages=()
    local installed_count=0

    for pkg in "${required_packages[@]}"; do
        local pkg_installed=false

        # Check main package name
        if rpm -q "$pkg" &>/dev/null; then
            pkg_installed=true
        # Check alternative package name
        elif [[ -n "${package_alternatives[$pkg]:-}" ]]; then
            if rpm -q "${package_alternatives[$pkg]}" &>/dev/null; then
                pkg_installed=true
                log_debug "  $pkg (via ${package_alternatives[$pkg]})"
            fi
        fi

        if [[ "$pkg_installed" == true ]]; then
            log_debug "  $pkg"
            ((installed_count++))
        else
            log_info "  $pkg (needs installation)"
            missing_packages+=("$pkg")
        fi
    done

    log_info "Packages: $installed_count installed, ${#missing_packages[@]} missing"

    if ((${#missing_packages[@]} > 0)); then
        log_info "Installing missing packages..."
        if sudo dnf install -y "${missing_packages[@]}" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
            log_success "Build dependencies installed"
        else
            log_error "Failed to install some packages"
            return 1
        fi
    else
        log_success "All build dependencies already installed"
    fi

    return 0
}

# Configure pesign for user
setup_pesign_user() {
    log_info "Configuring pesign for current user..."

    # Check if user is in pesign users file
    if ! grep -q "^${USER}$" /etc/pesign/users 2>/dev/null; then
        log_info "Adding $USER to pesign users..."
        sudo bash -c "echo $USER >> /etc/pesign/users"
    fi

    # Run pesign-authorize
    if sudo /usr/libexec/pesign/pesign-authorize 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_success "Pesign configured for user $USER"
    else
        log_warn "Pesign authorization may have issues (often safe to ignore)"
    fi

    return 0
}

# ============================================================================
# Resource Setup
# ============================================================================

# Setup resources from upstream repository
setup_resources() {
    log_section "Resource Setup"

    log_info "Fetching resources from upstream GitHub repository"
    log_info "Repository: ${AUDIO_FIX_REPO:-$DEFAULT_AUDIO_FIX_REPO}"

    if ! fetch_all_resources; then
        log_error "Failed to fetch upstream resources"
        log_info "Please check your internet connection and try again"
        return 1
    fi

    log_success "Upstream resources ready"
    return 0
}

# ============================================================================
# MOK/Signing Setup - Simplified Logic
# ============================================================================

# Get MOK status as a bitmask
# Returns: 0=all ok, 1=files missing, 2=not enrolled, 4=pesign not configured
get_mok_status() {
    local status=0
    local cert_name="${MOK_CERT_NAME:-MOK Signing Key}"

    check_mok_files_exist || status=$((status | 1))
    check_mok_enrolled    || status=$((status | 2))

    if ! check_pesign_cert "$cert_name" || ! check_pesign_key "$cert_name"; then
        status=$((status | 4))
    fi

    echo $status
}

# Handle MOK setup based on status
handle_mok_setup() {
    local status=$1

    case $status in
        0)
            log_success "MOK signing fully configured - ready to build!"
            return 0
            ;;
        1|3|5|7)
            # Files missing (possibly with other issues)
            prompt_create_mok_key || return 1
            # Recheck after key creation
            handle_mok_setup "$(get_mok_status)"
            ;;
        2|6)
            # Files exist but not enrolled (possibly pesign issue too)
            prompt_enroll_mok || return 1
            ;;
        4)
            # Only pesign not configured
            log_info "Importing MOK into pesign database..."
            import_to_pesign || return 1
            log_success "MOK signing setup complete!"
            ;;
    esac
}

# Prompt user to create MOK key
prompt_create_mok_key() {
    echo ""
    log_warn "MOK key files are missing"
    echo ""
    echo "Options:"
    echo "  1) Create new MOK key (recommended for first-time setup)"
    echo "  2) Specify path to existing MOK key"
    echo "  3) Continue without signing (ENABLE_SIGNING=false)"
    echo "  4) Abort and configure manually"
    echo ""
    echo -n "Choice [1-4]: "
    read -r choice

    case "$choice" in
        1)
            create_mok_key || return 1
            ;;
        2)
            echo ""
            echo -n "Enter path to MOK directory: "
            read -r custom_path
            if [[ -f "${custom_path}/MOK.priv" && -f "${custom_path}/MOK.der" ]]; then
                MOK_KEY_DIR="$custom_path"
                log_success "Using MOK from: $custom_path"
            else
                log_error "MOK files not found in: $custom_path"
                return 1
            fi
            ;;
        3)
            ENABLE_SIGNING=false
            log_info "Signing disabled - continuing without signature"
            return 0
            ;;
        *)
            log_info "Aborting. Configure MOK manually and re-run."
            return 1
            ;;
    esac
}

# Prompt user to enroll MOK
prompt_enroll_mok() {
    echo ""
    log_warn "MOK key exists but is not enrolled in UEFI"

    # Check if EFI is supported
    if ! check_efi_support; then
        log_error "EFI/UEFI is not supported on this system"
        log_warn ""
        log_warn "This system appears to be running in:"
        log_warn "  - Legacy BIOS mode, OR"
        log_warn "  - A VM without UEFI support, OR"
        log_warn "  - An environment without EFI variable access"
        log_warn ""
        log_info "MOK enrollment is not possible without UEFI support"
        log_info "You can continue building the kernel without Secure Boot signing"
        echo ""
        echo "Options:"
        echo "  1) Continue without signing (kernel will work on systems with Secure Boot disabled)"
        echo "  2) Exit script"
        echo ""
        echo -n "Choice [1-2]: "
        read -r choice

        case "$choice" in
            1)
                ENABLE_SIGNING=false
                log_info "Signing disabled - continuing without signature"
                return 0
                ;;
            *)
                echo ""
                log_info "Build aborted by user"
                log_info ""
                log_info "To use Secure Boot signing, you need to:"
                log_info "  1. Boot your system in UEFI mode (not Legacy BIOS)"
                log_info "  2. If using a VM, enable UEFI firmware in VM settings"
                log_info "  3. Ensure EFI variables are accessible (/sys/firmware/efi/efivars)"
                log_info ""
                log_info "To build without signing:"
                log_info "  - For this build only: ./build-kernel.sh --no-sign"
                log_info "  - Permanently: set ENABLE_SIGNING=false in config/build.conf"
                echo ""
                exit 0
                ;;
        esac
    fi

    log_warn "Enrollment requires a reboot"
    echo ""
    echo "Options:"
    echo "  1) Enroll MOK now (will require reboot before build)"
    echo "  2) Continue without signing"
    echo "  3) Abort"
    echo ""
    echo -n "Choice [1-3]: "
    read -r choice

    case "$choice" in
        1)
            enroll_mok || return 1
            save_state "PENDING_MOK_ENROLLMENT"
            echo ""
            echo -e "${YELLOW}=======================================${NC}"
            echo -e "${YELLOW}  REBOOT REQUIRED FOR MOK ENROLLMENT${NC}"
            echo -e "${YELLOW}=======================================${NC}"
            echo ""
            echo "After reboot:"
            echo "  1. MOK Manager will appear - follow prompts to enroll"
            echo "  2. Re-run this script to continue the build"
            echo ""
            echo -n "Reboot now? [Y/n]: "
            read -r reboot_choice
            if [[ ! "$reboot_choice" =~ ^[Nn]$ ]]; then
                sudo reboot
            fi
            exit 0
            ;;
        2)
            ENABLE_SIGNING=false
            log_info "Signing disabled - continuing without signature"
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Preliminary MOK setup check
check_mok_setup_preliminary() {
    log_section "Secure Boot / MOK Preliminary Check"

    # Skip if signing disabled
    if [[ "${ENABLE_SIGNING:-true}" != true ]]; then
        log_info "Kernel signing is disabled (ENABLE_SIGNING=false)"
        log_warn "Built kernel will NOT be signed for Secure Boot"
        return 0
    fi

    log_info "Signing is enabled - checking MOK prerequisites..."

    local status
    status=$(get_mok_status)

    # Log current status
    if ((status & 1)); then
        log_info "  MOK key files: missing"
    else
        log_info "  MOK key files: present"
    fi

    if ((status & 2)); then
        log_info "  MOK enrollment: not enrolled"
    else
        log_info "  MOK enrollment: enrolled"
    fi

    if ((status & 4)); then
        log_info "  Pesign database: not configured"
    else
        log_info "  Pesign database: configured"
    fi

    # Handle based on status
    handle_mok_setup "$status"
}

# ============================================================================
# Resume from State
# ============================================================================

# Check and handle saved state (for resuming after reboot)
check_resume_state() {
    local saved_state
    saved_state=$(load_state)

    if [[ -z "$saved_state" ]]; then
        return 0
    fi

    log_section "Resuming from Previous State"
    log_info "Found saved state: $saved_state"

    case "$saved_state" in
        "PENDING_MOK_ENROLLMENT")
            log_info "Checking if MOK enrollment completed..."
            if check_mok_enrolled; then
                log_success "MOK enrollment successful!"
                clear_state

                # Continue with pesign setup
                local cert_name="${MOK_CERT_NAME:-MOK Signing Key}"
                if ! check_pesign_cert "$cert_name"; then
                    log_info "Setting up pesign database..."
                    if ! import_to_pesign; then
                        log_error "Failed to setup pesign"
                        return 1
                    fi
                fi

                log_success "Ready to continue with build!"
                return 0
            else
                log_error "MOK enrollment does not appear to have completed"
                log_info "Did you complete the MOK Manager prompts at boot?"
                clear_state
                return 1
            fi
            ;;
        *)
            log_warn "Unknown state: $saved_state"
            clear_state
            return 0
            ;;
    esac
}

# ============================================================================
# Main Setup Workflow
# ============================================================================

# Run all setup checks and initialization
run_setup() {
    log_section "Pre-flight Setup Checks"

    local setup_failed=false

    # Check for resume state first
    if ! check_resume_state; then
        return 1
    fi

    # Check Fedora
    if ! check_fedora; then
        return 1
    fi

    # Check disk space
    if ! check_disk_space; then
        return 1
    fi

    # Install dependencies
    if ! install_build_dependencies; then
        log_error "Failed to install build dependencies"
        setup_failed=true
    fi

    # Setup pesign user permissions
    setup_pesign_user || true

    # Setup resources from upstream
    if ! setup_resources; then
        log_error "Failed to setup resources"
        setup_failed=true
    fi

    # Check MOK/Signing (preliminary)
    if ! check_mok_setup_preliminary; then
        log_error "MOK/Signing setup failed"
        setup_failed=true
    fi

    if [[ "$setup_failed" == true ]]; then
        log_error "Setup checks failed"
        return 1
    fi

    log_success "All setup checks passed!"
    return 0
}

# Quick setup check (for --check option)
quick_setup_check() {
    log_section "Quick Setup Check"

    echo ""
    echo "=== System ==="
    echo -n "Fedora: "
    if check_fedora &>/dev/null; then
        echo -e "${GREEN}OK${NC} ($(rpm -E %fedora))"
    else
        echo -e "${RED}Not Fedora${NC}"
    fi

    echo ""
    echo "=== Dependencies ==="
    local deps=(fedpkg pesign mokutil git)
    for dep in "${deps[@]}"; do
        echo -n "$dep: "
        if command -v "$dep" &>/dev/null; then
            echo -e "${GREEN}Installed${NC}"
        else
            echo -e "${RED}Missing${NC}"
        fi
    done

    echo ""
    echo "=== Resources ==="
    show_resource_status

    echo ""
    echo "=== Signing ==="
    show_mok_status

    return 0
}
