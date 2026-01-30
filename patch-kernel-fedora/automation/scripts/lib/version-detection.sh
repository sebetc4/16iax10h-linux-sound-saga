#!/bin/bash
# Kernel Version Detection Library
# Handles Fedora release detection and kernel version selection

# Detect current Fedora release
detect_fedora_release() {
    if [[ ! -f /etc/fedora-release ]]; then
        log_error "This system is not Fedora"
        return 1
    fi

    local fedora_version
    fedora_version=$(rpm -E %fedora)
    echo "f${fedora_version}"
}

# List available kernel versions from git repository
# Args: $1 = repo_dir, $2 = max versions per major release (default: 3)
list_available_kernel_versions() {
    local repo_dir="$1"
    local max_per_major="${2:-3}"

    log_debug "Listing available versions in $repo_dir"

    if ! cd "$repo_dir" 2>/dev/null; then
        log_error "Cannot access repository: $repo_dir"
        return 1
    fi

    # Extract all kernel versions from git history
    local all_versions
    all_versions=$(git log --oneline --all 2>/dev/null \
        | grep -oP 'kernel-\K[0-9]+\.[0-9]+\.[0-9]+-[0-9]+' \
        | sort -Vru)

    if [[ -z "$all_versions" ]]; then
        log_error "No kernel versions found in git repository"
        return 1
    fi

    log_debug "Found $(echo "$all_versions" | wc -l) unique versions"

    # Group by major version (e.g., 6.18, 6.19)
    local major_versions
    major_versions=$(echo "$all_versions" | cut -d. -f1-2 | sort -Vru)

    log_debug "Major versions: $(echo "$major_versions" | tr '\n' ' ')"

    # Select top N versions per major release
    local selected_versions=""
    local major
    for major in $major_versions; do
        local versions
        versions=$(echo "$all_versions" | grep "^${major}\." | head -n "$max_per_major")
        selected_versions="${selected_versions}${versions}"$'\n'
    done

    # Return non-empty lines
    echo "$selected_versions" | grep -v '^$'
}

# Interactive menu for kernel version selection
# Args: $1 = versions (newline-separated), $2 = max display count (default: 20)
select_kernel_version() {
    local versions="$1"
    local max_display="${2:-20}"

    local -a version_array
    local line

    # Build version array
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        version_array+=("$line")
    done <<< "$versions"

    local total=${#version_array[@]}
    local display_count=$((total < max_display ? total : max_display))

    # Display menu (on stderr so stdout can capture selection)
    {
        echo ""
        echo "Available versions (${display_count}/${total}):"
        echo ""

        local i
        for ((i = 0; i < display_count; i++)); do
            printf "  [%2d] kernel-%s\n" "$((i + 1))" "${version_array[$i]}"
        done

        if ((total > max_display)); then
            echo "  ... and $((total - max_display)) older versions"
        fi

        echo ""
        echo -n "Select version [1-${display_count}]: "
    } >&2

    local choice
    read -r choice

    # Validate input
    if [[ ! "$choice" =~ ^[0-9]+$ ]]; then
        echo "[ERROR] Invalid input: expected a number" >&2
        return 1
    fi

    if ((choice < 1 || choice > display_count)); then
        echo "[ERROR] Invalid choice: $choice (enter a number between 1 and $display_count)" >&2
        return 1
    fi

    # Return selected version (array is 0-indexed)
    echo "${version_array[$((choice - 1))]}"
}

# Find git commit hash for a specific kernel version
# Args: $1 = repo_dir, $2 = version string
find_commit_for_version() {
    local repo_dir="$1"
    local version="$2"

    if ! cd "$repo_dir" 2>/dev/null; then
        log_error "Cannot access repository: $repo_dir"
        return 1
    fi

    local commit
    commit=$(git log --oneline --all 2>/dev/null \
        | grep -F "kernel-${version}" \
        | head -n1 \
        | awk '{print $1}')

    if [[ -z "$commit" ]]; then
        log_error "Commit not found for kernel-${version}"
        return 1
    fi

    echo "$commit"
}
