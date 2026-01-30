#!/bin/bash
# Configuration Validator Library
# Validates build configuration and applies sensible defaults

# Apply default values for optional configuration settings
apply_config_defaults() {
    # Logging defaults
    : "${LOG_LEVEL:=INFO}"
    : "${LOG_DIR:=/tmp/kernel-build-logs}"

    # Build defaults
    : "${BUILD_ID:=.custom}"
    : "${MAX_VERSIONS_PER_MAJOR:=5}"
    : "${BUILD_WITHOUT_SELFTESTS:=true}"
    : "${BUILD_WITHOUT_DEBUG:=true}"
    : "${BUILD_WITHOUT_DEBUGINFO:=false}"

    # Path defaults
    : "${WORK_DIR:=$HOME/fedora-kernel-build}"
    : "${RESOURCE_CACHE_DIR:=${WORK_DIR}/resources}"

    # Signing defaults
    : "${ENABLE_SIGNING:=true}"
    : "${MOK_CERT_NAME:=MOK Signing Key}"
    : "${MOK_KEY_CN:=Kernel Signing Key}"
    : "${MOK_VALIDITY_DAYS:=36500}"

    # Cleanup defaults
    : "${ARCHIVE_RPMS:=true}"
    : "${ARCHIVE_DIR:=${WORK_DIR}/archives}"

    # State management
    : "${STATE_FILE:=/tmp/kernel-build-state}"

    # Security
    : "${AUTO_INSTALL:=false}"

    # Post-build actions
    : "${SET_DEFAULT_KERNEL:=false}"
}

# Validate required configuration settings
# Returns: 0 if valid, 1 if errors found
validate_config() {
    local errors=0

    # Validate LOG_LEVEL
    case "$LOG_LEVEL" in
        DEBUG|INFO|WARN|ERROR) ;;
        *)
            log_error "Invalid LOG_LEVEL: '$LOG_LEVEL' (must be DEBUG, INFO, WARN, or ERROR)"
            ((errors++))
            ;;
    esac

    # Validate WORK_DIR is set and parent exists
    if [[ -z "$WORK_DIR" ]]; then
        log_error "WORK_DIR is not set"
        ((errors++))
    else
        local parent_dir
        parent_dir=$(dirname "$WORK_DIR")
        if [[ ! -d "$parent_dir" ]]; then
            log_error "WORK_DIR parent directory does not exist: $parent_dir"
            ((errors++))
        fi
    fi

    # Validate BUILD_ID format (should start with . or be empty)
    if [[ -n "$BUILD_ID" && ! "$BUILD_ID" =~ ^\. ]]; then
        log_warn "BUILD_ID should start with '.' (e.g., '.audio'). Current: '$BUILD_ID'"
    fi

    # Validate MAX_VERSIONS_PER_MAJOR is a positive integer
    if [[ ! "$MAX_VERSIONS_PER_MAJOR" =~ ^[0-9]+$ ]] || ((MAX_VERSIONS_PER_MAJOR < 1)); then
        log_error "MAX_VERSIONS_PER_MAJOR must be a positive integer: '$MAX_VERSIONS_PER_MAJOR'"
        ((errors++))
    fi

    # Validate MOK_VALIDITY_DAYS is a positive integer
    if [[ ! "$MOK_VALIDITY_DAYS" =~ ^[0-9]+$ ]] || ((MOK_VALIDITY_DAYS < 1)); then
        log_error "MOK_VALIDITY_DAYS must be a positive integer: '$MOK_VALIDITY_DAYS'"
        ((errors++))
    fi

    # Validate boolean settings
    local bool_vars=(
        "ENABLE_SIGNING"
        "BUILD_WITHOUT_SELFTESTS"
        "BUILD_WITHOUT_DEBUG"
        "BUILD_WITHOUT_DEBUGINFO"
        "ARCHIVE_RPMS"
        "AUTO_INSTALL"
        "SET_DEFAULT_KERNEL"
    )

    for var in "${bool_vars[@]}"; do
        local value="${!var}"
        if [[ "$value" != "true" && "$value" != "false" ]]; then
            log_error "$var must be 'true' or 'false': '$value'"
            ((errors++))
        fi
    done

    # Validate ARCHIVE_DIR if archiving is enabled
    if [[ "$ARCHIVE_RPMS" == "true" && -n "$ARCHIVE_DIR" ]]; then
        local archive_parent
        archive_parent=$(dirname "$ARCHIVE_DIR")
        if [[ ! -d "$archive_parent" && ! -w "$(dirname "$archive_parent")" ]]; then
            log_warn "ARCHIVE_DIR parent may not be writable: $archive_parent"
        fi
    fi

    # Validate AUDIO_FIX_REPO URL format
    if [[ -n "$AUDIO_FIX_REPO" ]]; then
        if [[ ! "$AUDIO_FIX_REPO" =~ ^https?:// && ! "$AUDIO_FIX_REPO" =~ ^git@ ]]; then
            log_error "AUDIO_FIX_REPO must be a valid git URL: '$AUDIO_FIX_REPO'"
            ((errors++))
        fi
    fi

    return $((errors > 0 ? 1 : 0))
}

# Check if all required external tools are available
# Returns: 0 if all present, 1 if missing tools
check_required_tools() {
    local required_tools=(
        "git"
        "fedpkg"
        "rpmbuild"
        "dnf"
    )

    local optional_tools=(
        "pesign"
        "mokutil"
        "sbverify"
        "certutil"
    )

    local missing=0

    log_debug "Checking required tools..."

    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_error "Required tool not found: $tool"
            ((missing++))
        else
            log_debug "Found: $tool"
        fi
    done

    if ((missing > 0)); then
        log_error "Missing $missing required tool(s)"
        return 1
    fi

    # Check optional tools (warn only)
    for tool in "${optional_tools[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            log_debug "Optional tool not found: $tool"
        fi
    done

    log_debug "All required tools present"
    return 0
}

# Validate and prepare configuration
# This is the main entry point for config validation
# Returns: 0 on success, 1 on failure
validate_and_prepare_config() {
    log_debug "Applying configuration defaults..."
    apply_config_defaults

    log_debug "Validating configuration..."
    if ! validate_config; then
        log_error "Configuration validation failed"
        return 1
    fi

    log_debug "Configuration validated successfully"
    return 0
}

# Display current configuration (for debugging)
show_config() {
    echo ""
    echo "=== Current Configuration ==="
    echo ""
    echo "Paths:"
    echo "  WORK_DIR=$WORK_DIR"
    echo "  LOG_DIR=$LOG_DIR"
    echo "  ARCHIVE_DIR=$ARCHIVE_DIR"
    echo "  RESOURCE_CACHE_DIR=$RESOURCE_CACHE_DIR"
    echo ""
    echo "Build Options:"
    echo "  BUILD_ID=$BUILD_ID"
    echo "  FEDORA_RELEASE=${FEDORA_RELEASE:-auto}"
    echo "  BUILD_WITHOUT_SELFTESTS=$BUILD_WITHOUT_SELFTESTS"
    echo "  BUILD_WITHOUT_DEBUG=$BUILD_WITHOUT_DEBUG"
    echo "  BUILD_WITHOUT_DEBUGINFO=$BUILD_WITHOUT_DEBUGINFO"
    echo ""
    echo "Signing:"
    echo "  ENABLE_SIGNING=$ENABLE_SIGNING"
    echo "  MOK_KEY_DIR=${MOK_KEY_DIR:-default}"
    echo "  MOK_CERT_NAME=$MOK_CERT_NAME"
    echo ""
    echo "Logging:"
    echo "  LOG_LEVEL=$LOG_LEVEL"
    echo ""
}
