#!/bin/bash
# Resource Manager Library
# Downloads patches, firmware, and UCM2 files from upstream repository

# Default upstream repository
DEFAULT_AUDIO_FIX_REPO="https://github.com/nadimkobeissi/16iax10h-linux-sound-saga.git"

# Local cache directory for downloaded resources
RESOURCE_CACHE_DIR="${RESOURCE_CACHE_DIR:-${WORK_DIR}/resources}"

# ============================================================================
# Repository Management
# ============================================================================

# Clone or update the audio fix repository
clone_audio_fix_repo() {
    local repo_url="${AUDIO_FIX_REPO:-$DEFAULT_AUDIO_FIX_REPO}"
    local repo_dir="${RESOURCE_CACHE_DIR}/16iax10h-linux-sound-saga"

    log_section "Fetching Audio Fix Resources"

    # Create cache directory
    mkdir -p "$RESOURCE_CACHE_DIR"

    if [[ -d "$repo_dir/.git" ]]; then
        # Repository exists, update it
        log_info "Updating existing repository..."
        if ! git -C "$repo_dir" pull --ff-only 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
            log_warn "Pull failed, trying fresh clone..."
            rm -rf "$repo_dir"
        else
            log_success "Repository updated"
            return 0
        fi
    fi

    # Clone fresh
    log_info "Cloning repository: $repo_url"
    if ! git clone --depth 1 "$repo_url" "$repo_dir" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_error "Failed to clone repository"
        return 1
    fi

    log_success "Repository cloned successfully"

    # Show commit info
    local commit_hash
    local commit_date
    commit_hash=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null)
    commit_date=$(git -C "$repo_dir" log -1 --format=%ci 2>/dev/null)
    log_info "Using commit: $commit_hash ($commit_date)"

    return 0
}

# ============================================================================
# Patch Management
# ============================================================================

# Get the appropriate patch file for kernel version
get_patch_file() {
    local kernel_version="$1"
    local repo_dir="${RESOURCE_CACHE_DIR}/16iax10h-linux-sound-saga"
    local patches_dir="${repo_dir}/fix/patches"

    if [[ ! -d "$patches_dir" ]]; then
        log_error "Patches directory not found: $patches_dir"
        log_info "Run clone_audio_fix_repo first"
        return 1
    fi

    # Extract major.minor version (e.g., 6.18 from 6.18.6)
    local major_minor
    major_minor=$(echo "$kernel_version" | grep -oP '^\d+\.\d+')

    local patch_file=""

    # Try exact match first (e.g., 16iax10h-audio-linux-6.18.patch)
    if [[ -f "${patches_dir}/16iax10h-audio-linux-${major_minor}.patch" ]]; then
        patch_file="${patches_dir}/16iax10h-audio-linux-${major_minor}.patch"
    # Try with full version
    elif [[ -f "${patches_dir}/16iax10h-audio-linux-${kernel_version}.patch" ]]; then
        patch_file="${patches_dir}/16iax10h-audio-linux-${kernel_version}.patch"
    # Fallback: find any patch for this major version
    else
        local major
        major=$(echo "$kernel_version" | cut -d. -f1)
        patch_file=$(find "$patches_dir" -name "16iax10h-audio-linux-${major}.*.patch" 2>/dev/null \
            | sort -V \
            | tail -1)
    fi

    if [[ -z "$patch_file" || ! -f "$patch_file" ]]; then
        log_error "No suitable patch found for kernel $kernel_version"
        log_info "Available patches:"
        find "$patches_dir" -name "*.patch" -type f 2>/dev/null | while read -r f; do
            log_info "  - $(basename "$f")"
        done
        return 1
    fi

    log_debug "Found patch: $patch_file"
    echo "$patch_file"
    return 0
}

# Copy patch to kernel build directory
install_patch() {
    local kernel_version="$1"
    local dest_dir="$2"

    log_info "Installing patch for kernel $kernel_version..."

    local patch_file
    if ! patch_file=$(get_patch_file "$kernel_version"); then
        return 1
    fi

    local patch_name
    patch_name=$(basename "$patch_file")
    local dest_path="${dest_dir}/${patch_name}"

    if ! cp "$patch_file" "$dest_path"; then
        log_error "Failed to copy patch to $dest_path"
        return 1
    fi

    log_success "Patch installed: $patch_name"
    echo "$patch_name"
    return 0
}

# ============================================================================
# Firmware Management
# ============================================================================

# Get firmware file path
get_firmware_file() {
    local repo_dir="${RESOURCE_CACHE_DIR}/16iax10h-linux-sound-saga"
    local firmware_file="${repo_dir}/fix/firmware/aw88399_acf.bin"

    if [[ ! -f "$firmware_file" ]]; then
        log_error "Firmware file not found: $firmware_file"
        return 1
    fi

    echo "$firmware_file"
    return 0
}

# Install firmware to system
install_firmware() {
    local firmware_dest="/lib/firmware/aw88399_acf.bin"

    log_info "Installing AW88399 firmware..."

    # Get source file
    local firmware_file
    if ! firmware_file=$(get_firmware_file); then
        return 1
    fi

    # Check if already installed with same content
    if [[ -f "$firmware_dest" ]]; then
        local source_md5
        local dest_md5
        source_md5=$(md5sum "$firmware_file" | cut -d' ' -f1)
        dest_md5=$(md5sum "$firmware_dest" | cut -d' ' -f1)

        if [[ "$source_md5" == "$dest_md5" ]]; then
            log_success "Firmware already installed and up to date"
            return 0
        fi
        log_info "Firmware differs, updating..."
    fi

    # Copy to system
    if ! sudo cp "$firmware_file" "$firmware_dest"; then
        log_error "Failed to copy firmware to $firmware_dest"
        return 1
    fi

    # Set permissions
    sudo chmod 644 "$firmware_dest"

    log_success "Firmware installed: $firmware_dest"
    return 0
}

# ============================================================================
# UCM2 Configuration Management
# ============================================================================

# Get UCM2 files directory
get_ucm2_dir() {
    local repo_dir="${RESOURCE_CACHE_DIR}/16iax10h-linux-sound-saga"
    local ucm2_dir="${repo_dir}/fix/ucm2"

    if [[ ! -d "$ucm2_dir" ]]; then
        log_error "UCM2 directory not found: $ucm2_dir"
        return 1
    fi

    echo "$ucm2_dir"
    return 0
}

# Install UCM2 configuration files
install_ucm2() {
    local ucm2_dest="/usr/share/alsa/ucm2/HDA"

    log_info "Installing UCM2 configuration files..."

    # Get source directory
    local ucm2_source
    if ! ucm2_source=$(get_ucm2_dir); then
        return 1
    fi

    # Verify destination exists
    if [[ ! -d "$ucm2_dest" ]]; then
        log_error "UCM2 destination directory not found: $ucm2_dest"
        log_info "Is alsa-ucm installed?"
        return 1
    fi

    # Files to install
    local ucm2_files=(
        "HiFi-analog.conf"
        "HiFi-mic.conf"
    )

    local installed_count=0

    for file in "${ucm2_files[@]}"; do
        local source_file="${ucm2_source}/${file}"
        local dest_file="${ucm2_dest}/${file}"
        local backup_file="${dest_file}.orig"

        if [[ ! -f "$source_file" ]]; then
            log_warn "UCM2 source file not found: $source_file"
            continue
        fi

        # Create backup if original exists and no backup yet
        if [[ -f "$dest_file" && ! -f "$backup_file" ]]; then
            log_info "Backing up original: $file"
            sudo cp "$dest_file" "$backup_file" || true
        fi

        # Copy new file
        if ! sudo cp -f "$source_file" "$dest_file"; then
            log_error "Failed to copy $file to $ucm2_dest"
            continue
        fi

        log_success "Installed: $file"
        ((installed_count++))
    done

    if ((installed_count == 0)); then
        log_error "No UCM2 files were installed"
        return 1
    fi

    log_success "UCM2 configuration installed ($installed_count files)"
    return 0
}

# Restore original UCM2 files from backup
restore_ucm2() {
    local ucm2_dest="/usr/share/alsa/ucm2/HDA"

    log_info "Restoring original UCM2 configuration..."

    local ucm2_files=(
        "HiFi-analog.conf"
        "HiFi-mic.conf"
    )

    local restored_count=0

    for file in "${ucm2_files[@]}"; do
        local dest_file="${ucm2_dest}/${file}"
        local backup_file="${dest_file}.orig"

        if [[ -f "$backup_file" ]]; then
            if sudo mv "$backup_file" "$dest_file"; then
                log_success "Restored: $file"
                ((restored_count++))
            else
                log_error "Failed to restore $file"
            fi
        else
            log_info "No backup found for $file"
        fi
    done

    log_info "Restored $restored_count UCM2 files"
    return 0
}

# ============================================================================
# Complete Resource Setup
# ============================================================================

# Fetch all resources from upstream repository
fetch_all_resources() {
    log_section "Fetching All Resources from Upstream"

    # Clone/update repository
    if ! clone_audio_fix_repo; then
        return 1
    fi

    # Verify resources are available
    local repo_dir="${RESOURCE_CACHE_DIR}/16iax10h-linux-sound-saga"

    log_info "Verifying resources..."

    # Check patches using array glob (more efficient than ls | wc)
    if [[ -d "${repo_dir}/fix/patches" ]]; then
        local patches=("${repo_dir}/fix/patches"/*.patch)
        if [[ -e "${patches[0]}" ]]; then
            log_success "Patches available: ${#patches[@]}"
        else
            log_error "No patch files found"
            return 1
        fi
    else
        log_error "Patches directory missing"
        return 1
    fi

    # Check firmware
    if [[ -f "${repo_dir}/fix/firmware/aw88399_acf.bin" ]]; then
        log_success "Firmware available: aw88399_acf.bin"
    else
        log_error "Firmware file missing"
        return 1
    fi

    # Check UCM2 using array glob
    if [[ -d "${repo_dir}/fix/ucm2" ]]; then
        local ucm2_files=("${repo_dir}/fix/ucm2"/*.conf)
        if [[ -e "${ucm2_files[0]}" ]]; then
            log_success "UCM2 configs available: ${#ucm2_files[@]}"
        else
            log_warn "No UCM2 config files found"
        fi
    else
        log_error "UCM2 directory missing"
        return 1
    fi

    log_success "All resources fetched successfully"
    return 0
}

# Install all resources (firmware + UCM2)
install_all_resources() {
    log_section "Installing Audio Resources"

    local errors=0

    # Install firmware
    if ! install_firmware; then
        log_error "Firmware installation failed"
        ((errors++))
    fi

    # Install UCM2
    if ! install_ucm2; then
        log_warn "UCM2 installation failed (can be done manually later)"
    fi

    if ((errors > 0)); then
        return 1
    fi

    return 0
}

# Show resource status
show_resource_status() {
    local repo_dir="${RESOURCE_CACHE_DIR}/16iax10h-linux-sound-saga"

    echo ""
    echo "=== Resource Status ==="
    echo ""

    # Repository
    echo -n "Upstream Repository: "
    if [[ -d "$repo_dir/.git" ]]; then
        local commit
        commit=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null)
        echo -e "${GREEN}Cloned${NC} (commit: $commit)"
    else
        echo -e "${YELLOW}Not cloned${NC}"
    fi

    # Firmware
    echo -n "System Firmware: "
    if [[ -f "/lib/firmware/aw88399_acf.bin" ]]; then
        echo -e "${GREEN}Installed${NC}"
    else
        echo -e "${RED}Missing${NC}"
    fi

    # UCM2
    echo -n "UCM2 Config: "
    if [[ -f "/usr/share/alsa/ucm2/HDA/HiFi-analog.conf" ]]; then
        if [[ -f "/usr/share/alsa/ucm2/HDA/HiFi-analog.conf.orig" ]]; then
            echo -e "${GREEN}Installed (custom)${NC}"
        else
            echo -e "${YELLOW}Default${NC}"
        fi
    else
        echo -e "${RED}Missing${NC}"
    fi

    echo ""
}
