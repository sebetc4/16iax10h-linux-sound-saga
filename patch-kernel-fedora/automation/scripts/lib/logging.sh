#!/bin/bash
# Logging Library for Kernel Build Scripts
# Provides consistent logging with levels, colors, and file output

# Terminal colors (only if stdout is a terminal)
if [[ -t 1 ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m'
else
    readonly RED=''
    readonly GREEN=''
    readonly YELLOW=''
    readonly BLUE=''
    readonly NC=''
fi

# Log level constants (for comparison)
declare -A LOG_LEVELS=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)

# Global log configuration
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_FILE=""

# Initialize logging system
# Args: $1 = log directory path
init_logging() {
    local log_dir="$1"

    if [[ -z "$log_dir" ]]; then
        log_dir="/tmp"
    fi

    mkdir -p "$log_dir" 2>/dev/null || {
        echo "[WARN] Cannot create log directory: $log_dir, using /tmp" >&2
        log_dir="/tmp"
    }

    LOG_FILE="${log_dir}/build-$(date +%Y-%m-%d-%H-%M-%S).log"

    # Create log file with header
    {
        echo "=== Kernel Build Log ==="
        echo "Started: $(date)"
        echo "User: ${USER:-unknown}"
        echo "Host: $(hostname)"
        echo "========================"
        echo ""
    } > "$LOG_FILE"

    log_info "Log file initialized: $LOG_FILE"
}

# Internal: Check if message should be logged based on level
_should_log() {
    local level="$1"
    local current_level="${LOG_LEVELS[$LOG_LEVEL]:-1}"
    local msg_level="${LOG_LEVELS[$level]:-1}"
    ((msg_level >= current_level))
}

# Internal: Write to log file
_log_to_file() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ -n "$LOG_FILE" && -w "$LOG_FILE" ]]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

# Log debug message
log_debug() {
    _should_log "DEBUG" || return 0
    _log_to_file "DEBUG" "$*"
    echo -e "${BLUE}[DEBUG]${NC} $*"
}

# Log info message
log_info() {
    _should_log "INFO" || return 0
    _log_to_file "INFO" "$*"
    echo -e "${GREEN}[INFO]${NC} $*"
}

# Log warning message
log_warn() {
    _should_log "WARN" || return 0
    _log_to_file "WARN" "$*"
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

# Log error message
log_error() {
    _log_to_file "ERROR" "$*"
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# Log success message (always shown)
log_success() {
    _log_to_file "SUCCESS" "$*"
    echo -e "${GREEN}[OK]${NC} $*"
}

# Log section header
log_section() {
    local title="$*"
    _log_to_file "SECTION" "$title"
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  $title${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
}

# Log step in a process
# Args: $1 = step number/id, $2+ = description
log_step() {
    local step="$1"
    shift
    local description="$*"
    _log_to_file "STEP" "[$step] $description"
    echo -e "${GREEN}[Step $step]${NC} $description"
}

# Exit with error message
# Args: $1+ = error message
error_exit() {
    log_error "$*"
    if [[ -n "$LOG_FILE" ]]; then
        log_error "Build failed. Check log: $LOG_FILE"
    fi
    exit 1
}

# Get current log file path
get_log_file() {
    echo "$LOG_FILE"
}
