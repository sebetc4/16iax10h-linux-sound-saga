#!/bin/bash
# MOK (Machine Owner Key) Manager for Secure Boot Signing
# Handles MOK key creation, verification, and pesign database setup

# Default MOK key location
DEFAULT_MOK_DIR="/var/lib/shim-signed/mok"

# State file for resuming after reboot
STATE_FILE="${STATE_FILE:-/tmp/kernel-build-state}"

# ============================================================================
# MOK Key Verification Functions
# ============================================================================

# Check if system supports EFI/UEFI
check_efi_support() {
    # Check for EFI system directory
    if [[ ! -d /sys/firmware/efi ]]; then
        log_debug "EFI support check: /sys/firmware/efi not found"
        return 1
    fi

    # Check for EFI variables directory
    if [[ ! -d /sys/firmware/efi/efivars ]] && [[ ! -d /sys/firmware/efi/vars ]]; then
        log_debug "EFI support check: EFI variables directory not found"
        return 1
    fi

    log_debug "EFI support check: system supports EFI/UEFI"
    return 0
}

# Check if MOK key files exist on disk
check_mok_files_exist() {
    local mok_dir="${MOK_KEY_DIR:-$DEFAULT_MOK_DIR}"
    local priv_key="${mok_dir}/MOK.priv"
    local der_cert="${mok_dir}/MOK.der"

    log_debug "Checking MOK files in: $mok_dir"

    if [[ -f "$priv_key" && -f "$der_cert" ]]; then
        log_debug "MOK key files found: $priv_key, $der_cert"
        return 0
    fi

    log_debug "MOK key files not found"
    return 1
}

# Check if MOK is enrolled in UEFI
check_mok_enrolled() {
    local mok_dir="${MOK_KEY_DIR:-$DEFAULT_MOK_DIR}"
    local der_cert="${mok_dir}/MOK.der"

    if ! command -v mokutil &>/dev/null; then
        log_warn "mokutil not installed, cannot verify MOK enrollment"
        return 1
    fi

    # If we have a specific certificate, check for it
    if [[ -f "$der_cert" ]]; then
        local local_fingerprint
        local_fingerprint=$(openssl x509 -inform DER -in "$der_cert" -noout -fingerprint -sha1 2>/dev/null \
            | cut -d= -f2 \
            | tr '[:upper:]' '[:lower:]')

        log_debug "check_mok_enrolled: der_cert=$der_cert"
        log_debug "check_mok_enrolled: local_fingerprint=$local_fingerprint"

        if [[ -n "$local_fingerprint" ]]; then
            local mokutil_output
            mokutil_output=$(mokutil --list-enrolled 2>/dev/null)

            if echo "$mokutil_output" | grep -qF "$local_fingerprint"; then
                log_debug "Your MOK certificate is enrolled in UEFI"
                return 0
            fi
            log_debug "Your MOK certificate is not enrolled (but other MOKs may be)"
            return 1
        fi
    fi

    # Fallback: Check if any MOK is enrolled
    if mokutil --list-enrolled 2>/dev/null | grep -q "Subject:"; then
        log_debug "MOK keys enrolled in UEFI (cannot verify if it's yours)"
        return 0
    fi

    log_debug "No MOK keys enrolled in UEFI"
    return 1
}

# Check if specific certificate is enrolled in MOK
check_cert_enrolled() {
    local cert_cn="$1"

    if mokutil --list-enrolled 2>/dev/null | grep -qF "CN=$cert_cn"; then
        log_debug "Certificate '$cert_cn' is enrolled in MOK"
        return 0
    fi

    log_debug "Certificate '$cert_cn' not found in enrolled MOKs"
    return 1
}

# Check if certificate exists in pesign NSS database
check_pesign_cert() {
    local cert_name="$1"

    if ! command -v certutil &>/dev/null; then
        log_error "certutil not installed"
        return 1
    fi

    if sudo certutil -d /etc/pki/pesign -L 2>/dev/null | grep -qF "$cert_name"; then
        log_debug "Certificate '$cert_name' found in pesign database"
        return 0
    fi

    log_debug "Certificate '$cert_name' not found in pesign database"
    return 1
}

# Check if private key exists in pesign NSS database
check_pesign_key() {
    local cert_name="$1"

    if sudo certutil -d /etc/pki/pesign -K 2>/dev/null | grep -qF "$cert_name"; then
        log_debug "Private key for '$cert_name' found in pesign database"
        return 0
    fi

    log_debug "Private key for '$cert_name' not found in pesign database"
    return 1
}

# ============================================================================
# MOK Key Creation Functions
# ============================================================================

# Create new MOK key pair
create_mok_key() {
    local mok_dir="${MOK_KEY_DIR:-$DEFAULT_MOK_DIR}"
    local key_cn="${MOK_KEY_CN:-Kernel Signing Key}"
    local validity_days="${MOK_VALIDITY_DAYS:-36500}"
    local key_size="${MOK_KEY_SIZE:-2048}"

    log_section "Creating New MOK Key Pair"

    # Create directory
    log_info "Creating MOK directory: $mok_dir"
    if ! sudo mkdir -p "$mok_dir"; then
        log_error "Failed to create MOK directory"
        return 1
    fi

    # Generate key pair
    log_info "Generating RSA ${key_size}-bit key pair..."
    if ! sudo openssl req -new -x509 -newkey "rsa:${key_size}" \
        -keyout "${mok_dir}/MOK.priv" \
        -outform DER -out "${mok_dir}/MOK.der" \
        -days "$validity_days" \
        -subj "/CN=${key_cn}/" \
        -nodes 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_error "Failed to generate MOK key pair"
        return 1
    fi

    log_success "Key pair generated"

    # Convert to PEM format
    log_info "Converting certificate to PEM format..."
    if ! sudo openssl x509 -inform DER \
        -in "${mok_dir}/MOK.der" \
        -out "${mok_dir}/MOK.pem" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_error "Failed to convert certificate to PEM"
        return 1
    fi

    log_success "PEM certificate created"

    # Set secure permissions
    sudo chmod 600 "${mok_dir}/MOK.priv"
    sudo chmod 644 "${mok_dir}/MOK.der" "${mok_dir}/MOK.pem"

    log_success "MOK key pair created successfully"
    log_info "Files created:"
    log_info "  Private key: ${mok_dir}/MOK.priv"
    log_info "  DER cert:    ${mok_dir}/MOK.der"
    log_info "  PEM cert:    ${mok_dir}/MOK.pem"

    return 0
}

# Enroll MOK in UEFI (requires reboot)
enroll_mok() {
    local mok_dir="${MOK_KEY_DIR:-$DEFAULT_MOK_DIR}"
    local der_cert="${mok_dir}/MOK.der"

    log_section "Enrolling MOK in UEFI"

    if [[ ! -f "$der_cert" ]]; then
        log_error "MOK certificate not found: $der_cert"
        return 1
    fi

    # Check if system supports EFI
    if ! check_efi_support; then
        log_error "EFI/UEFI is not supported on this system"
        log_warn "MOK enrollment requires UEFI firmware"
        log_warn ""
        log_warn "This system appears to be running in:"
        log_warn "  - Legacy BIOS mode, OR"
        log_warn "  - A VM without UEFI support, OR"
        log_warn "  - An environment without EFI variable access"
        log_warn ""
        log_info "You can continue building the kernel, but it will not be signed for Secure Boot"
        log_info "The kernel will still work on systems with Secure Boot disabled"
        return 1
    fi

    log_info "Importing MOK certificate..."
    log_warn "You will be prompted to set a one-time password"
    log_warn "Remember this password - you'll need it after reboot!"
    echo ""

    if ! sudo mokutil --import "$der_cert"; then
        log_error "Failed to import MOK certificate"
        return 1
    fi

    log_success "MOK certificate queued for enrollment"
    log_warn ""
    log_warn "IMPORTANT: You must reboot to complete MOK enrollment!"
    log_warn ""
    log_warn "After reboot, the MOK Manager will appear:"
    log_warn "  1. Select 'Enroll MOK'"
    log_warn "  2. Select 'Continue'"
    log_warn "  3. Select 'Yes' to confirm"
    log_warn "  4. Enter the password you just set"
    log_warn "  5. Select 'Reboot'"
    log_warn ""

    return 0
}

# ============================================================================
# Pesign Database Setup Functions
# ============================================================================

# Import MOK key into pesign NSS database
import_to_pesign() {
    local mok_dir="${MOK_KEY_DIR:-$DEFAULT_MOK_DIR}"
    local cert_name="${MOK_CERT_NAME:-MOK Signing Key}"
    local priv_key="${mok_dir}/MOK.priv"
    local pem_cert="${mok_dir}/MOK.pem"

    log_section "Importing MOK to Pesign Database"

    # Verify files exist
    if [[ ! -f "$priv_key" || ! -f "$pem_cert" ]]; then
        log_error "MOK key files not found in $mok_dir"
        return 1
    fi

    # Create PKCS#12 file with secure temporary file
    log_info "Creating PKCS#12 bundle..."
    local p12_file
    p12_file=$(sudo mktemp --tmpdir MOK-XXXXXX.p12)

    # Ensure cleanup on function exit
    trap 'sudo shred -u "$p12_file" 2>/dev/null || sudo rm -f "$p12_file"' RETURN

    # Set restrictive permissions immediately
    sudo chmod 600 "$p12_file"

    if ! sudo openssl pkcs12 -export \
        -out "$p12_file" \
        -inkey "$priv_key" \
        -in "$pem_cert" \
        -name "$cert_name" \
        -passout pass: 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_error "Failed to create PKCS#12 file"
        return 1
    fi

    log_success "PKCS#12 bundle created"

    # Check and remove existing entry if present
    if sudo certutil -d /etc/pki/pesign -L 2>/dev/null | grep -qF "$cert_name"; then
        log_warn "Certificate '$cert_name' already exists in pesign database"
        log_info "Removing existing entry to replace it..."
        sudo certutil -d /etc/pki/pesign -D -n "$cert_name" 2>/dev/null || true
    fi

    # Import into pesign database
    log_info "Importing into pesign NSS database..."
    if ! sudo pk12util -d /etc/pki/pesign -i "$p12_file" -W "" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_error "Failed to import into pesign database"
        return 1
    fi

    log_success "MOK imported to pesign database"

    # Verify import
    log_info "Verifying pesign import..."

    echo ""
    echo "=== Pesign Certificates ==="
    sudo certutil -d /etc/pki/pesign -L
    echo ""

    if check_pesign_cert "$cert_name" && check_pesign_key "$cert_name"; then
        log_success "Certificate and private key verified in pesign database"
        return 0
    else
        log_error "Verification failed - check pesign database"
        return 1
    fi
}

# ============================================================================
# State Management
# ============================================================================

# Save state for resuming after reboot
save_state() {
    local state="$1"
    local kernel_version="${2:-}"

    {
        echo "STATE=$state"
        echo "KERNEL_VERSION=$kernel_version"
        echo "TIMESTAMP=$(date +%s)"
    } > "$STATE_FILE"

    log_debug "State saved: $state"
}

# Load saved state (safely, without sourcing)
load_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo ""
        return
    fi

    local state_value=""
    while IFS='=' read -r key value; do
        # Strip whitespace
        key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty lines and comments
        [[ -z "$key" || "$key" =~ ^# ]] && continue

        if [[ "$key" == "STATE" ]]; then
            state_value="$value"
            break
        fi
    done < "$STATE_FILE"

    echo "$state_value"
}

# Clear saved state
clear_state() {
    rm -f "$STATE_FILE"
    log_debug "State cleared"
}

# ============================================================================
# Full MOK Setup Workflow
# ============================================================================

# Complete MOK setup workflow with user prompts
setup_mok_workflow() {
    local mok_dir="${MOK_KEY_DIR:-$DEFAULT_MOK_DIR}"
    local cert_name="${MOK_CERT_NAME:-MOK Signing Key}"

    log_section "MOK Signing Setup Workflow"

    # Step 1: Check if MOK files exist
    log_step "1" "Checking for existing MOK key files"

    if check_mok_files_exist; then
        log_success "MOK key files found in $mok_dir"
    else
        log_warn "MOK key files not found"

        # Check if user provided custom path
        if [[ -n "${MOK_KEY_DIR:-}" && "$MOK_KEY_DIR" != "$DEFAULT_MOK_DIR" ]]; then
            log_error "Custom MOK path specified but files not found: $MOK_KEY_DIR"
            log_info "Please verify the path or remove the MOK_KEY_DIR setting"
            return 1
        fi

        # Ask user what to do
        echo ""
        echo -e "${YELLOW}No MOK key found. What would you like to do?${NC}"
        echo "  1) Create a new MOK key pair"
        echo "  2) Specify path to existing MOK key"
        echo "  3) Skip signing (build without signature)"
        echo ""
        echo -n "Choice [1-3]: "
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
                    export MOK_KEY_DIR="$custom_path"
                    log_success "Using MOK from: $custom_path"
                    log_info "MOK_KEY_DIR exported for this session"
                else
                    log_error "MOK files not found in: $custom_path"
                    log_info "Expected files: MOK.priv, MOK.der"
                    return 1
                fi
                ;;
            3)
                log_info "Skipping kernel signing"
                ENABLE_SIGNING=false
                return 0
                ;;
            *)
                log_error "Invalid choice"
                return 1
                ;;
        esac
    fi

    # Step 2: Check if MOK is enrolled in UEFI
    log_step "2" "Checking MOK enrollment in UEFI"

    if check_mok_enrolled; then
        log_success "MOK keys are enrolled in UEFI"
    else
        log_warn "MOK not enrolled in UEFI"

        echo ""
        echo -e "${YELLOW}MOK needs to be enrolled in UEFI. This requires a reboot.${NC}"
        echo ""
        echo "Options:"
        echo "  1) Enroll MOK now (will save state and prompt for reboot)"
        echo "  2) Continue without signing (can sign later)"
        echo ""
        echo -n "Choice [1-2]: "
        read -r choice

        case "$choice" in
            1)
                enroll_mok || return 1

                save_state "MOK_ENROLLED_PENDING_REBOOT"

                echo ""
                echo -e "${YELLOW}========================================${NC}"
                echo -e "${YELLOW}  REBOOT REQUIRED${NC}"
                echo -e "${YELLOW}========================================${NC}"
                echo ""
                echo "After reboot, run this script again."
                echo "It will resume from where it left off."
                echo ""
                echo -n "Reboot now? [y/N]: "
                read -r reboot_choice

                if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
                    log_warn "Rebooting in 5 seconds... (Ctrl+C to cancel)"
                    sleep 5
                    sudo reboot
                else
                    log_info "Please reboot manually when ready"
                    log_info "Then run: $0"
                    exit 0
                fi
                ;;
            2)
                log_info "Continuing without signing"
                ENABLE_SIGNING=false
                return 0
                ;;
            *)
                log_error "Invalid choice"
                return 1
                ;;
        esac
    fi

    # Step 3: Check pesign database
    log_step "3" "Checking pesign database setup"

    if check_pesign_cert "$cert_name" && check_pesign_key "$cert_name"; then
        log_success "MOK already configured in pesign database"
    else
        log_info "MOK not found in pesign database, importing..."
        import_to_pesign || return 1
    fi

    log_section "MOK Setup Complete"
    log_success "Kernel signing is ready!"
    log_info "Certificate name: $cert_name"

    # Clear any pending state
    clear_state

    return 0
}

# Check if signing prerequisites are met (quick check)
check_signing_prerequisites() {
    local cert_name="${MOK_CERT_NAME:-MOK Signing Key}"

    # Check pesign is installed
    if ! command -v pesign &>/dev/null; then
        log_debug "pesign not installed"
        return 1
    fi

    # Check certificate and key in pesign database
    if ! check_pesign_cert "$cert_name"; then
        log_debug "Certificate not in pesign database"
        return 1
    fi

    if ! check_pesign_key "$cert_name"; then
        log_debug "Private key not in pesign database"
        return 1
    fi

    return 0
}

# Display MOK status summary
show_mok_status() {
    local mok_dir="${MOK_KEY_DIR:-$DEFAULT_MOK_DIR}"
    local cert_name="${MOK_CERT_NAME:-MOK Signing Key}"

    echo ""
    echo "=== MOK Status Summary ==="
    echo ""

    # Key files
    echo -n "MOK Key Files ($mok_dir): "
    if check_mok_files_exist; then
        echo -e "${GREEN}Present${NC}"
    else
        echo -e "${RED}Missing${NC}"
    fi

    # UEFI enrollment
    echo -n "MOK Enrolled in UEFI: "
    if check_mok_enrolled; then
        echo -e "${GREEN}Yes${NC}"
    else
        echo -e "${RED}No${NC}"
    fi

    # Pesign database
    echo -n "Pesign Certificate: "
    if check_pesign_cert "$cert_name"; then
        echo -e "${GREEN}Present${NC}"
    else
        echo -e "${RED}Missing${NC}"
    fi

    echo -n "Pesign Private Key: "
    if check_pesign_key "$cert_name"; then
        echo -e "${GREEN}Present${NC}"
    else
        echo -e "${RED}Missing${NC}"
    fi

    # Overall status
    echo ""
    echo -n "Signing Ready: "
    if check_signing_prerequisites; then
        echo -e "${GREEN}Yes${NC}"
    else
        echo -e "${RED}No${NC}"
    fi

    echo ""
}
