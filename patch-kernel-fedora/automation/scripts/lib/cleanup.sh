#!/bin/bash
# Cleanup Library for Kernel Build Artifacts
# Handles archiving and removal of build directories

# ============================================================================
# RPM Archiving
# ============================================================================

# Archive kernel RPMs to compressed archive
archive_kernel_rpms() {
    local kernel_version="$1"

    if [[ -z "$kernel_version" ]]; then
        log_error "Kernel version not specified for archiving"
        return 1
    fi

    log_section "Archiving Kernel RPMs"

    local rpm_dir="${WORK_DIR}/kernel/x86_64"
    if [[ ! -d "$rpm_dir" ]]; then
        log_warn "RPM directory not found: $rpm_dir"
        log_warn "Nothing to archive"
        return 1
    fi

    local archive_name="kernel-${kernel_version}-rpms.tar.gz"
    local temp_archive_dir="${WORK_DIR}/archive"

    # List of essential RPMs to archive
    local rpm_patterns=(
        "kernel-${kernel_version}.rpm"
        "kernel-core-${kernel_version}.rpm"
        "kernel-modules-${kernel_version}.rpm"
        "kernel-modules-core-${kernel_version}.rpm"
        "kernel-modules-extra-${kernel_version}.rpm"
        "kernel-devel-${kernel_version}.rpm"
    )

    # Create temporary archive directory
    mkdir -p "$temp_archive_dir"

    # Copy essential RPMs
    log_info "Copying essential RPMs to archive..."
    local copied_count=0
    for pattern in "${rpm_patterns[@]}"; do
        local rpm_file="${rpm_dir}/${pattern}"
        if [[ -f "$rpm_file" ]]; then
            cp "$rpm_file" "$temp_archive_dir/"
            log_info "  + $(basename "$rpm_file")"
            ((copied_count++))
        else
            log_debug "  - Not found: $(basename "$rpm_file")"
        fi
    done

    if ((copied_count == 0)); then
        log_error "No RPMs were copied to archive"
        rm -rf "$temp_archive_dir"
        return 1
    fi

    # Create compressed archive
    log_info "Creating compressed archive..."
    mkdir -p "$ARCHIVE_DIR"

    if tar -czf "${ARCHIVE_DIR}/${archive_name}" -C "${WORK_DIR}" archive/ 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
        log_success "Archive created: ${ARCHIVE_DIR}/${archive_name}"

        # Show archive info
        local archive_size
        archive_size=$(du -h "${ARCHIVE_DIR}/${archive_name}" | cut -f1)
        log_info "Archive size: $archive_size"
        log_info "Archive contains $copied_count RPM files"

        # Remove temporary archive directory
        rm -rf "$temp_archive_dir"

        return 0
    else
        log_error "Failed to create archive"
        rm -rf "$temp_archive_dir"
        return 1
    fi
}

# ============================================================================
# Build Directory Cleanup
# ============================================================================

# Clean up build directories
cleanup_build_directories() {
    log_section "Cleaning up Build Directories"

    local dirs_to_clean=(
        "${WORK_DIR}"
    )

    log_warn "This will permanently delete build directories!"
    log_info "Directories to remove:"

    local total_size=0
    for dir in "${dirs_to_clean[@]}"; do
        if [[ -d "$dir" ]]; then
            local dir_size
            dir_size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            log_info "  - $dir (size: $dir_size)"
        fi
    done

    # Ask for confirmation in interactive mode
    if [[ -t 0 ]]; then
        echo ""
        echo -e "${YELLOW}Do you want to proceed with cleanup? [y/N]${NC}"
        read -r response
        if [[ ! "$response" =~ ^[Yy]$ ]]; then
            log_info "Cleanup cancelled by user"
            return 0
        fi
    fi

    # Remove directories
    for dir in "${dirs_to_clean[@]}"; do
        if [[ -d "$dir" ]]; then
            local dir_size
            dir_size=$(du -sh "$dir" 2>/dev/null | cut -f1)
            log_info "Removing: $dir (size: $dir_size)"
            if rm -rf "$dir" 2>&1 | tee -a "${LOG_FILE:-/dev/null}"; then
                log_success "Removed: $dir"
            else
                log_error "Failed to remove: $dir"
            fi
        else
            log_info "Directory not found, skipping: $dir"
        fi
    done

    log_success "Build directories cleaned up"

    return 0
}

# ============================================================================
# Complete Cleanup Workflow
# ============================================================================

# Run complete cleanup workflow
run_cleanup() {
    local kernel_version="$1"

    if [[ -z "$kernel_version" ]]; then
        log_error "Kernel version not specified for cleanup"
        return 1
    fi

    # Archive RPMs if enabled
    if [[ "${ARCHIVE_RPMS:-true}" == true ]]; then
        if archive_kernel_rpms "$kernel_version"; then
            log_info ""
            log_info "RPMs archived successfully"
            log_info "To restore RPMs later:"
            log_info "  cd ${ARCHIVE_DIR}"
            log_info "  tar -xzf kernel-${kernel_version}-rpms.tar.gz"
            log_info "  cd archive"
            log_info "  sudo dnf install -y *.rpm"
            log_info ""
        else
            log_warn "Failed to archive RPMs, skipping cleanup for safety"
            log_warn "Build directories preserved: ${WORK_DIR}"
            return 1
        fi
    else
        log_info "Skipping RPM archiving (ARCHIVE_RPMS=false in config)"
        log_warn "Build directories will be removed without archiving RPMs!"

        if [[ -t 0 ]]; then
            echo ""
            echo -e "${YELLOW}Are you sure you want to proceed? [y/N]${NC}"
            read -r response
            if [[ ! "$response" =~ ^[Yy]$ ]]; then
                log_info "Cleanup cancelled by user"
                return 0
            fi
        fi
    fi

    # Clean up directories
    cleanup_build_directories

    return 0
}

# ============================================================================
# Utility Functions
# ============================================================================

# List archived kernels
list_archived_kernels() {
    log_info "Archived kernels in ${ARCHIVE_DIR}:"
    echo ""

    if [[ ! -d "$ARCHIVE_DIR" ]]; then
        log_info "Archive directory does not exist"
        return 0
    fi

    local archives=("${ARCHIVE_DIR}"/kernel-*-rpms.tar.gz)
    if [[ ! -e "${archives[0]}" ]]; then
        log_info "No kernel archives found"
        return 0
    fi

    for archive in "${archives[@]}"; do
        local name
        local size
        name=$(basename "$archive")
        size=$(du -h "$archive" | cut -f1)
        echo "  $name ($size)"
    done

    echo ""
}

# Restore archived kernel RPMs
restore_archived_kernel() {
    local archive_name="$1"
    local dest_dir="${2:-$(pwd)}"

    if [[ -z "$archive_name" ]]; then
        log_error "Archive name required"
        list_archived_kernels
        return 1
    fi

    local archive_path="${ARCHIVE_DIR}/${archive_name}"

    if [[ ! -f "$archive_path" ]]; then
        log_error "Archive not found: $archive_path"
        list_archived_kernels
        return 1
    fi

    log_info "Extracting $archive_name to $dest_dir..."

    if tar -xzf "$archive_path" -C "$dest_dir"; then
        log_success "Archive extracted to ${dest_dir}/archive/"
        log_info "To install: cd ${dest_dir}/archive && sudo dnf install -y *.rpm"
        return 0
    else
        log_error "Failed to extract archive"
        return 1
    fi
}
