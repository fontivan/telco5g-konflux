#!/usr/bin/env bash

# This script automates the download and installation of Go tools using 'go install'.
# It creates a temporary Go module, installs the tool, and cleans up.
# It checks if the tool is already available in the local install directory
# and only downloads if needed.

# Configure shell to exit immediately if a command exits with a non-zero status,
# treat unset variables as an error, and fail a pipeline if any command fails.
set -eou pipefail

# Determine the absolute path of the directory containing this script. This allows
# the script to reliably locate other files relative to its own location.
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

# Default installation directory relative to the script's location.
DEFAULT_INSTALL_DIR="${SCRIPT_DIR}/../bin"

usage() {
    cat << EOF
Usage: $0 [OPTIONS] TOOL_NAME GO_MODULE

Downloads and installs Go tools using 'go install' if necessary.
Checks local install directory first, and only downloads if the tool is not found.

Arguments:
    TOOL_NAME            Name of the tool binary (e.g., controller-gen)
    GO_MODULE            Go module path with version (e.g., sigs.k8s.io/controller-tools/cmd/controller-gen@v0.15.0)

Options:
    -d, --install-dir DIR Install directory (default: ${DEFAULT_INSTALL_DIR})
    -f, --force           Force download even if tool already exists
    -h, --help            Show this help message

Environment Variables:
    INSTALL_DIR           Install directory (overridden by -d/--install-dir)

Examples:
    $0 controller-gen sigs.k8s.io/controller-tools/cmd/controller-gen@v0.15.0
    $0 -d /usr/local/bin mockgen github.com/golang/mock/mockgen@v1.6.0
    $0 --force ginkgo github.com/onsi/ginkgo/v2/ginkgo@v2.17.2
    $0 --help

EOF
}

# Function to check if two version strings are exactly equal
# Returns 0 if version1 == version2, 1 otherwise
version_exact_match() {
    local version1="$1"
    local version2="$2"

    # Remove 'v' prefix if present
    version1="${version1#v}"
    version2="${version2#v}"

    # Check for exact match
    if [[ "$version1" == "$version2" ]]; then
        return 0  # versions match exactly
    else
        return 1  # versions don't match
    fi
}

# Function to extract version from go module string (part after @)
extract_version_from_module() {
    local go_module="$1"
    echo "${go_module##*@}"
}

# Function to get version from a Go tool binary
# This is challenging because Go tools don't have a standard version format
# We'll try common patterns: go version -m, --version, version, -version
get_tool_version() {
    local binary_path="$1"
    if [[ ! -x "$binary_path" ]]; then
        return 1
    fi

    # Try go version -m first: reads the module version embedded in the binary's
    # build metadata by the Go toolchain at install time. This is the most reliable
    # method for Go binaries installed via 'go install pkg@version' because it
    # bypasses the binary's own version command (which may print "(devel)" when
    # built from source without a release tag).
    local go_mod_version
    if command -v go > /dev/null 2>&1; then
        if go_mod_version=$(go version -m "$binary_path" 2>/dev/null | awk '$1 == "mod" {print $3; exit}') && [[ -n "$go_mod_version" ]] && [[ "$go_mod_version" != "(devel)" ]]; then
            echo "$go_mod_version"
            return 0
        fi
    fi

    # Fall back to querying the binary directly using common version flag patterns
    local version_output=""

    # Try --version flag
    if version_output=$(bash -c "$binary_path --version" 2>/dev/null | head -1); then
        # Look for version patterns: v1.2.3, 1.2.3, version 1.2.3, etc.
        if echo "$version_output" | grep -qE '(v?[0-9]+\.[0-9]+\.[0-9]+)'; then
            echo "$version_output" | grep -oE '(v?[0-9]+\.[0-9]+\.[0-9]+)' | head -1
            return 0
        fi
    fi

    # Try version command (no dashes)
    if version_output=$(bash -c "$binary_path version" 2>/dev/null | head -1); then
        if echo "$version_output" | grep -qE '(v?[0-9]+\.[0-9]+\.[0-9]+)'; then
            echo "$version_output" | grep -oE '(v?[0-9]+\.[0-9]+\.[0-9]+)' | head -1
            return 0
        fi
    fi

    # Try -version flag
    if version_output=$(bash -c "$binary_path -version" 2>/dev/null | head -1); then
        if echo "$version_output" | grep -qE '(v?[0-9]+\.[0-9]+\.[0-9]+)'; then
            echo "$version_output" | grep -oE '(v?[0-9]+\.[0-9]+\.[0-9]+)' | head -1
            return 0
        fi
    fi

    # Could not determine version
    return 1
}

check_go() {
    if ! command -v go > /dev/null 2>&1; then
        echo "ERROR: Go is required but not found in PATH"
        echo "Please install Go and ensure it's in your PATH"
        exit 1
    fi

    # Check Go version (require 1.16+ for go install with version)
    local go_version
    if go_version=$(go version 2>/dev/null | grep -o 'go[0-9][0-9]*\.[0-9][0-9]*' | head -1); then
        local major minor
        major=$(echo "$go_version" | sed 's/go\([0-9]*\)\.\([0-9]*\).*/\1/')
        minor=$(echo "$go_version" | sed 's/go\([0-9]*\)\.\([0-9]*\).*/\2/')

        if [[ "$major" -lt 1 ]] || [[ "$major" -eq 1 && "$minor" -lt 16 ]]; then
            echo "ERROR: Go 1.16+ is required for 'go install' with version specifiers"
            echo "Found Go version: $go_version"
            echo "Please upgrade Go to 1.16 or later"
            exit 1
        fi
    else
        echo "WARNING: Could not determine Go version"
    fi

    echo "Using Go: $(go version)"
}

main() {
    # Parse command line arguments
    local install_dir="${INSTALL_DIR:-${DEFAULT_INSTALL_DIR}}"
    local force_download=false
    local tool_name=""
    local go_module=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -d|--install-dir)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --install-dir requires a directory argument"
                    usage
                    exit 1
                fi
                install_dir="$2"
                shift 2
                ;;
            -f|--force)
                force_download=true
                shift
                ;;
            -*)
                echo "Error: Unknown option $1"
                usage
                exit 1
                ;;
            *)
                if [[ -z "$tool_name" ]]; then
                    tool_name="$1"
                    shift
                elif [[ -z "$go_module" ]]; then
                    go_module="$1"
                    shift
                else
                    echo "Error: Too many arguments"
                    usage
                    exit 1
                fi
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$tool_name" ]]; then
        echo "Error: TOOL_NAME is required"
        usage
        exit 1
    fi

    if [[ -z "$go_module" ]]; then
        echo "Error: GO_MODULE is required"
        usage
        exit 1
    fi

    # Validate go_module format (should contain @ for version)
    if [[ ! "$go_module" =~ @ ]]; then
        echo "Error: GO_MODULE must include a version (e.g., package@version)"
        echo "Got: $go_module"
        usage
        exit 1
    fi

    # Extract the requested version from the Go module
    local requested_version
    requested_version=$(extract_version_from_module "$go_module")
    echo "Requested version: $requested_version"

    # Convert install_dir to absolute path
    if [[ ! -d "$install_dir" ]]; then
        mkdir -p "$install_dir"
    fi
    install_dir=$(cd "${install_dir}" && pwd)

    # Define the full path where the tool binary will be saved.
    local install_path="${install_dir}/${tool_name}"

    # Check if tool already exists with exact version (unless force is specified)
    if [[ "$force_download" == false ]]; then
        echo "Checking for ${tool_name} with exact version ${requested_version} in local install directory..."

        if [[ -x "$install_path" ]]; then
            echo "Found ${tool_name} in local install directory: $install_path"

            local local_version
            if local_version=$(get_tool_version "$install_path"); then
                echo "Local ${tool_name} version: $local_version"

                if version_exact_match "$local_version" "$requested_version"; then
                    echo "Local ${tool_name} version $local_version matches required version $requested_version"
                    return 0
                else
                    echo "Local ${tool_name} version $local_version does not match required version $requested_version"
                fi
            else
                echo "Could not determine local ${tool_name} version"
            fi
        else
            echo "${tool_name} not found in local install directory: $install_path"
        fi
    else
        echo "Force download enabled, will reinstall ${tool_name}..."
    fi

    # Check Go installation
    check_go

    # Install the tool
    echo "Installing ${tool_name} from ${go_module}..."

    # Create install directory
    echo "Creating directory '${install_dir}'"
    mkdir -p "${install_dir}"

    # Create temporary directory for Go module
    local temp_dir
    temp_dir=$(mktemp -d)
    echo "Created temporary directory: ${temp_dir}"

    # Change to temporary directory and set up Go module
    (
        cd "${temp_dir}"

        # Initialize temporary Go module
        echo "Initializing temporary Go module..."
        if ! go mod init tmp > /dev/null 2>&1; then
            echo "ERROR: Failed to initialize Go module"
            exit 1
        fi

        # Install the tool with GOBIN pointing to our install directory
        echo "Downloading ${go_module}..."
        if ! GOBIN="${install_dir}" go install "${go_module}"; then
            echo "ERROR: Failed to install ${go_module}"
            echo "Please check that the module path and version are correct"
            exit 1
        fi

        # Clean up go.mod and go.sum
        echo "Cleaning up temporary module files..."
        if ! go mod tidy > /dev/null 2>&1; then
            echo "WARNING: go mod tidy failed, but installation may have succeeded"
        fi
    )

    # Clean up temporary directory
    echo "Removing temporary directory: ${temp_dir}"
    rm -rf "${temp_dir}"

    # Verify the installation was successful
    if [[ ! -x "$install_path" ]]; then
        echo "ERROR: Tool was not installed to expected location: $install_path"
        exit 1
    fi

    # Get the actual installed version
    local actual_version
    if actual_version=$(get_tool_version "$install_path"); then
        echo "${tool_name} installed successfully to ${install_path}"
        echo "Installed version: ${actual_version}"

        # Check if the installed version matches what we requested
        if ! version_exact_match "$actual_version" "$requested_version"; then
            echo "WARNING: Requested version ${requested_version} but got: ${actual_version}"
        fi
    else
        echo "${tool_name} installed successfully to ${install_path}"
        echo "Version information not available (tool may not support standard version commands)"
    fi
}

# Execute the main function, passing along any arguments provided to the script.
main "$@"
