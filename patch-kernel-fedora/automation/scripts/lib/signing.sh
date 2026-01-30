#!/bin/bash
# Kernel Signing Library for Secure Boot
# Integrates with mok-manager.sh for complete signing workflow

# ============================================================================
# Kernel Signing Functions
# ============================================================================

# Sign kernel with pesign (Fedora native method)
sign_kernel_pesign() {
    local kernel_path="$1"
    local cert_name="${2:-${MOK_CERT_NAME:-MOK Signing Key}}"

    log_section "Kernel Signing"

    # Check if signing prerequisites are met
    if ! check_signing_prerequisites; then
        log_error "Signing prerequisites not met"
        log_info "Run the MOK setup workflow first"
        return 1
    fi

    log_success "Certificate '$cert_name' ready in pesign database"

    # Verify kernel file exists
    if [[ ! -f "$kernel_path" ]]; then
        log_error "Kernel file not found: $kernel_path"
        return 1
    fi

    # Backup original kernel
    log_info "Backing up unsigned kernel..."
    if [[ ! -f "${kernel_path}.unsigned" ]]; then
        sudo cp "$kernel_path" "${kernel_path}.unsigned"
        log_success "Backup: ${kernel_path}.unsigned"
    else
        log_info "Backup already exists, skipping"
    fi

    # Sign kernel
    log_info "Signing kernel with pesign..."
    local signed_path="${kernel_path}.signed"

    if ! sudo pesign -n /etc/pki/pesign -c "$cert_name" \
        -i "$kernel_path" \
        -o "$signed_path" \
        -s 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_error "Kernel signing failed"
        return 1
    fi

    log_success "Kernel signed successfully"

    # Replace original with signed version
    log_info "Replacing unsigned kernel with signed version..."
    if ! sudo mv "$signed_path" "$kernel_path"; then
        log_error "Failed to replace kernel with signed version"
        log_info "Signed version available at: $signed_path"
        return 1
    fi
    log_success "Kernel replaced: $kernel_path"

    # Regenerate GRUB config
    log_info "Regenerating GRUB configuration..."
    if sudo grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_success "GRUB configuration updated"
    else
        log_warn "GRUB config regeneration had warnings (usually safe to ignore)"
    fi

    # Verify signature
    verify_kernel_signature "$kernel_path"

    return 0
}

# Verify kernel signature
verify_kernel_signature() {
    local kernel_path="$1"

    log_info "Verifying kernel signature..."

    if ! command -v sbverify &>/dev/null; then
        log_warn "sbverify not installed, skipping verification"
        return 0
    fi

    if sudo sbverify --list "$kernel_path" &>/dev/null; then
        log_success "Kernel signature verified"

        # Show signatures
        echo ""
        echo "=== Kernel Signatures ==="
        sudo sbverify --list "$kernel_path" 2>&1 | grep -E "(signature|Subject|CN=)" | head -20
        echo ""

        # Count signatures
        local sig_count
        sig_count=$(sudo sbverify --list "$kernel_path" 2>&1 | grep -c "^signature" || echo 0)
        log_info "Total signatures: $sig_count"

        return 0
    else
        log_warn "Could not verify signature (sbverify failed)"
        return 1
    fi
}

# ============================================================================
# Signing Availability Checks
# ============================================================================

# Check if kernel signing is available (quick check)
check_signing_available() {
    local cert_name="${1:-${MOK_CERT_NAME:-MOK Signing Key}}"

    # Check if pesign is installed
    if ! command -v pesign &>/dev/null; then
        log_debug "pesign not installed"
        return 1
    fi

    # Check if certificate exists
    if ! sudo certutil -d /etc/pki/pesign -L 2>/dev/null | grep -qF "$cert_name"; then
        log_debug "Certificate '$cert_name' not found in pesign database"
        return 1
    fi

    # Check if private key exists
    if ! sudo certutil -d /etc/pki/pesign -K 2>/dev/null | grep -qF "$cert_name"; then
        log_debug "Private key for '$cert_name' not found"
        return 1
    fi

    return 0
}

# ============================================================================
# Pre-build Signing Verification
# ============================================================================

# Verify signing setup before starting build
verify_signing_setup() {
    local cert_name="${MOK_CERT_NAME:-MOK Signing Key}"

    log_section "Pre-build Signing Verification"

    if [[ "${ENABLE_SIGNING:-true}" != true ]]; then
        log_info "Kernel signing is disabled"
        log_warn "The kernel will NOT be signed for Secure Boot"
        return 0
    fi

    log_info "Checking MOK signing prerequisites..."

    # Check 1: MOK key files exist
    log_info "  Checking MOK key files..."
    if check_mok_files_exist; then
        log_success "  MOK key files: OK"
    else
        log_error "  MOK key files: MISSING"
        log_info ""
        log_info "MOK key files not found. Options:"
        log_info "  1. Set MOK_KEY_DIR in config to point to your keys"
        log_info "  2. Run the MOK setup workflow to create new keys"
        log_info "  3. Set ENABLE_SIGNING=false to skip signing"
        return 1
    fi

    # Check 2: MOK enrolled in UEFI
    log_info "  Checking MOK enrollment in UEFI..."
    if check_mok_enrolled; then
        log_success "  MOK enrollment: OK"
    else
        log_error "  MOK enrollment: NOT ENROLLED"
        log_info ""
        log_info "MOK key is not enrolled in UEFI. This requires a reboot."
        log_info "Run with --setup-mok to enroll the key."
        return 1
    fi

    # Check 3: Pesign database setup
    log_info "  Checking pesign database..."
    local has_cert=false
    local has_key=false
    check_pesign_cert "$cert_name" && has_cert=true
    check_pesign_key "$cert_name" && has_key=true

    if [[ "$has_cert" == true && "$has_key" == true ]]; then
        log_success "  Pesign database: OK"
    elif [[ "$has_cert" == true || "$has_key" == true ]]; then
        log_warn "  Pesign database: PARTIAL (cert=$has_cert, key=$has_key)"
        log_info "  Cleaning up partial configuration and re-importing..."
        sudo certutil -d /etc/pki/pesign -D -n "$cert_name" 2>/dev/null || true

        if import_to_pesign; then
            log_success "  Pesign database: OK (just configured)"
        else
            log_error "  Failed to configure pesign database"
            return 1
        fi
    else
        log_warn "  Pesign database: NOT CONFIGURED"
        log_info ""
        log_info "MOK key not imported into pesign database."
        log_info "Attempting to import automatically..."

        if import_to_pesign; then
            log_success "  Pesign database: OK (just configured)"
        else
            log_error "  Failed to configure pesign database"
            return 1
        fi
    fi

    log_success "Signing setup verified - ready to build and sign"
    return 0
}

# ============================================================================
# Interactive Signing Setup
# ============================================================================

# Interactive setup for signing (called with --setup-mok)
interactive_signing_setup() {
    log_section "Interactive MOK Signing Setup"

    # Show current status
    show_mok_status

    # Check if already configured
    if check_signing_prerequisites; then
        log_success "Signing is already fully configured!"
        echo ""
        echo -n "Do you want to reconfigure anyway? [y/N]: "
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    # Run the MOK workflow
    setup_mok_workflow
}

# ============================================================================
# Batch Signing (for multiple kernels)
# ============================================================================

# Sign all unsigned kernels matching a pattern
sign_all_kernels() {
    local pattern="${1:-*audio*}"
    local cert_name="${MOK_CERT_NAME:-MOK Signing Key}"

    log_section "Batch Kernel Signing"

    if ! check_signing_prerequisites; then
        log_error "Signing prerequisites not met"
        return 1
    fi

    local kernels=()
    local kernel_pattern="/boot/vmlinuz-${pattern}"

    # Use safe globbing
    shopt -s nullglob
    for kernel in $kernel_pattern; do
        [[ -f "$kernel" ]] && kernels+=("$kernel")
    done
    shopt -u nullglob

    if ((${#kernels[@]} == 0)); then
        log_info "No kernels matching pattern: $pattern"
        return 0
    fi

    log_info "Found ${#kernels[@]} kernel(s) to check"

    local signed_count=0
    for kernel in "${kernels[@]}"; do
        echo ""
        log_info "Checking: $(basename "$kernel")"

        # Check if already signed with our key
        if sudo sbverify --list "$kernel" 2>/dev/null | grep -qF "$cert_name"; then
            log_info "  Already signed with '$cert_name', skipping"
            continue
        fi

        # Sign the kernel
        if sign_kernel_pesign "$kernel" "$cert_name"; then
            ((signed_count++))
        else
            log_error "  Failed to sign $(basename "$kernel")"
        fi
    done

    echo ""
    log_success "Signed $signed_count kernel(s)"

    return 0
}
