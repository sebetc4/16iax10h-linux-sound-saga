#!/bin/bash
# Patch Manager Library
# Handles patch application and kernel.spec modification

# ============================================================================
# Patch Validation
# ============================================================================

# Validate patch file exists and has valid format
validate_patch() {
    local patch_file="$1"

    log_debug "Validating patch: $patch_file"

    if [[ ! -f "$patch_file" ]]; then
        log_error "Patch file not found: $patch_file"
        return 1
    fi

    # Check file is not empty
    if [[ ! -s "$patch_file" ]]; then
        log_error "Patch file is empty: $patch_file"
        return 1
    fi

    # Check patch format (should contain diff headers)
    local diff_count
    diff_count=$(grep -c "^diff " "$patch_file" 2>/dev/null || echo 0)

    if ((diff_count == 0)); then
        log_error "Patch contains no valid diffs: $patch_file"
        return 1
    fi

    log_debug "Patch valid: $diff_count files modified"
    return 0
}

# ============================================================================
# Patch Installation
# ============================================================================

# Copy patch to kernel directory
copy_patch_to_kernel() {
    local patch_src="$1"
    local kernel_dir="$2"

    log_step "5.1" "Copying audio patch"

    # Validate source patch
    if ! validate_patch "$patch_src"; then
        return 1
    fi

    # Check destination directory
    if [[ ! -d "$kernel_dir" ]]; then
        log_error "Kernel directory not found: $kernel_dir"
        return 1
    fi

    # Copy patch
    local patch_name
    patch_name=$(basename "$patch_src")

    if ! cp "$patch_src" "${kernel_dir}/${patch_name}"; then
        log_error "Failed to copy patch to $kernel_dir"
        return 1
    fi

    log_success "Patch copied: $patch_name"
    return 0
}

# ============================================================================
# kernel.spec Modification
# ============================================================================

# Modify kernel.spec to add patch and buildid
modify_kernel_spec() {
    local spec_file="$1"
    local patch_file="$2"
    local build_id="$3"

    log_step "5.2" "Modifying kernel.spec"

    # Validate inputs
    if [[ ! -f "$spec_file" ]]; then
        log_error "kernel.spec not found: $spec_file"
        return 1
    fi

    if [[ -z "$patch_file" ]]; then
        log_error "Patch file path is empty"
        return 1
    fi

    local patch_name
    patch_name=$(basename "$patch_file")

    # Backup original spec
    if [[ ! -f "${spec_file}.orig" ]]; then
        cp "$spec_file" "${spec_file}.orig"
        log_debug "Backup created: ${spec_file}.orig"
    fi

    # Step 1: Add patch declaration
    log_info "Adding patch declaration..."

    local patch_line
    patch_line=$(grep -n "^Patch999999:" "$spec_file" | cut -d: -f1)

    if [[ -z "$patch_line" ]]; then
        log_error "Patch999999 line not found in kernel.spec"
        log_info "Expected format: Patch999999: linux-kernel-test.patch"
        return 1
    fi

    # Insert patch declaration after Patch999999
    sed -i "${patch_line}a Patch10000: ${patch_name}" "$spec_file"
    log_success "Patch declared: Patch10000: $patch_name"

    # Step 2: Add patch application
    log_info "Adding patch application..."

    local apply_line
    apply_line=$(grep -n "ApplyOptionalPatch linux-kernel-test.patch" "$spec_file" | cut -d: -f1)

    if [[ -z "$apply_line" ]]; then
        log_error "ApplyOptionalPatch linux-kernel-test.patch line not found"
        log_info "Cannot determine where to add patch application"
        return 1
    fi

    # Insert patch application after linux-kernel-test.patch
    sed -i "${apply_line}a ApplyOptionalPatch ${patch_name}" "$spec_file"
    log_success "Patch application added"

    # Step 3: Modify buildid
    log_info "Setting buildid to '${build_id}'..."

    # Replace commented buildid with active buildid
    if grep -q "^# define buildid .local$" "$spec_file"; then
        sed -i "s/^# define buildid .local$/%define buildid ${build_id}/" "$spec_file"
    elif grep -q "^#define buildid" "$spec_file"; then
        sed -i "s/^#define buildid.*$/%define buildid ${build_id}/" "$spec_file"
    else
        log_warn "Could not find buildid line, adding at top of spec"
        sed -i "1i %define buildid ${build_id}" "$spec_file"
    fi

    # Verify buildid was modified
    if grep -q "^%define buildid ${build_id}" "$spec_file"; then
        log_success "BuildID set: ${build_id}"
    else
        log_error "Failed to set buildid"
        return 1
    fi

    # Step 4: Verification
    log_info "Verifying modifications..."

    echo ""
    echo "=== Declared Patches ==="
    grep "^Patch" "$spec_file" | tail -n 3

    echo ""
    echo "=== BuildID ==="
    grep "define buildid" "$spec_file" | grep -v "^#"

    echo ""
    echo "=== Applied Patches ==="
    grep "ApplyOptionalPatch" "$spec_file" | grep -v "ApplyOptionalPatch()" | tail -n 3

    echo ""

    log_success "kernel.spec modified successfully"
    return 0
}

# ============================================================================
# Utility Functions
# ============================================================================

# Restore original kernel.spec from backup
restore_kernel_spec() {
    local spec_file="$1"
    local backup_file="${spec_file}.orig"

    if [[ -f "$backup_file" ]]; then
        if mv "$backup_file" "$spec_file"; then
            log_success "kernel.spec restored from backup"
            return 0
        else
            log_error "Failed to restore kernel.spec"
            return 1
        fi
    else
        log_warn "No backup found for kernel.spec"
        return 1
    fi
}

# Show patch status in kernel.spec
show_patch_status() {
    local spec_file="$1"

    if [[ ! -f "$spec_file" ]]; then
        log_error "kernel.spec not found: $spec_file"
        return 1
    fi

    echo ""
    echo "=== Patch Configuration ==="
    echo ""

    echo "Declared patches:"
    grep "^Patch" "$spec_file" | tail -5 | while read -r line; do
        echo "  $line"
    done

    echo ""
    echo "Applied patches:"
    grep "ApplyOptionalPatch" "$spec_file" | grep -v "ApplyOptionalPatch()" | tail -5 | while read -r line; do
        echo "  $line"
    done

    echo ""
    echo "BuildID:"
    grep "define buildid" "$spec_file" | grep -v "^#" | while read -r line; do
        echo "  $line"
    done

    echo ""
}
