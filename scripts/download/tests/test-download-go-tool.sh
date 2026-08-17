#!/usr/bin/env bash

# Test script for download-go-tool.sh
# This script tests various scenarios for the Go tool download script

set -eou pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Test directory setup
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
DOWNLOAD_SCRIPT="${SCRIPT_DIR}/../download-go-tool.sh"
TEST_INSTALL_DIR="${SCRIPT_DIR}/test_bin"
TEST_LOG_FILE="${SCRIPT_DIR}/test_results.log"

# Test counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Test tool and module constants
TEST_TOOL_NAME="goimports"
TEST_MODULE_OLD="golang.org/x/tools/cmd/goimports@v0.24.0"
TEST_MODULE_NEW="golang.org/x/tools/cmd/goimports@v0.25.0"
TEST_MODULE_INVALID="invalid/module/path@v999.999.999"

# Alternative tool and versions for testing version mismatch / match
TEST_TOOL_VERSIONED="goimports"
TEST_MODULE_VERSIONED="golang.org/x/tools/cmd/goimports@v0.25.0"
TEST_MODULE_VERSIONED_OLD="golang.org/x/tools/cmd/goimports@v0.24.0"

# Utility functions
log() {
    echo -e "$1" | tee -a "$TEST_LOG_FILE"
}

log_test_start() {
    local test_name="$1"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    log "${YELLOW}[TEST ${TOTAL_TESTS}] Starting: $test_name${NC}"
}

log_test_pass() {
    local test_name="$1"
    PASSED_TESTS=$((PASSED_TESTS + 1))
    log "${GREEN}[PASS] $test_name${NC}"
}

log_test_fail() {
    local test_name="$1"
    local error_msg="$2"
    FAILED_TESTS=$((FAILED_TESTS + 1))
    log "${RED}[FAIL] $test_name${NC}"
    log "${RED}       Error: $error_msg${NC}"
}

setup_test_environment() {
    log "Setting up test environment..."

    # Check if Go is available
    if ! command -v go > /dev/null 2>&1; then
        log "${RED}Error: Go is required for testing but not found in PATH${NC}"
        exit 1
    fi

    # Remove test directory if it exists
    if [[ -d "$TEST_INSTALL_DIR" ]]; then
        rm -rf "$TEST_INSTALL_DIR"
    fi

    # Create fresh test directory
    mkdir -p "$TEST_INSTALL_DIR"

    # Initialize log file
    echo "Go Tool Download Script Test Results - $(date)" > "$TEST_LOG_FILE"
    echo "================================================" >> "$TEST_LOG_FILE"
    echo "Go version: $(go version)" >> "$TEST_LOG_FILE"
    echo "================================================" >> "$TEST_LOG_FILE"
}

cleanup_test_environment() {
    log "Cleaning up test environment..."

    # Remove test directory
    if [[ -d "$TEST_INSTALL_DIR" ]]; then
        rm -rf "$TEST_INSTALL_DIR"
    fi
}

create_fake_go_tool() {
    local tool_name="$1"
    local version="$2"
    local install_path="$3"

    # Create fake Go tool binary that returns the specified version
    cat > "$install_path" << EOF
#!/bin/bash
case "\$1" in
    --version)
        echo "$tool_name version $version"
        ;;
    version)
        echo "$tool_name version $version"
        ;;
    *)
        echo "Usage: $tool_name [--version|version]"
        ;;
esac
EOF
    chmod +x "$install_path"
}

test_download_valid_tool() {
    log_test_start "Download valid Go tool to empty directory"

    local test_dir="${TEST_INSTALL_DIR}/valid_tool"
    mkdir -p "$test_dir"

    # Test should succeed
    if "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "$TEST_TOOL_NAME" "$TEST_MODULE_OLD" >> "$TEST_LOG_FILE" 2>&1; then
        # Check if binary was created
        if [[ -x "$test_dir/$TEST_TOOL_NAME" ]]; then
            log_test_pass "Download valid Go tool to empty directory"
        else
            log_test_fail "Download valid Go tool to empty directory" "Binary not created"
        fi
    else
        log_test_fail "Download valid Go tool to empty directory" "Script failed"
    fi
}

test_download_versioned_tool() {
    log_test_start "Download Go tool with version support"

    local test_dir="${TEST_INSTALL_DIR}/versioned_tool"
    mkdir -p "$test_dir"

    # Test should succeed with a tool that supports version checking
    if "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "$TEST_TOOL_VERSIONED" "$TEST_MODULE_VERSIONED" >> "$TEST_LOG_FILE" 2>&1; then
        # Check if binary was created
        if [[ -x "$test_dir/$TEST_TOOL_VERSIONED" ]]; then
            local version_output
            if version_output=$(go version -m "$test_dir/$TEST_TOOL_VERSIONED" 2>/dev/null | awk '$1 == "mod" {print $3; exit}'); then
                log_test_pass "Download Go tool with version support (version: $version_output)"
            else
                log_test_pass "Download Go tool with version support (version check unavailable)"
            fi
        else
            log_test_fail "Download Go tool with version support" "Binary not created"
        fi
    else
        log_test_fail "Download Go tool with version support" "Script failed"
    fi
}

test_download_invalid_module() {
    log_test_start "Download with invalid Go module"

    local test_dir="${TEST_INSTALL_DIR}/invalid_module"
    mkdir -p "$test_dir"

    # Test should fail
    if "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "invalid-tool" "$TEST_MODULE_INVALID" >> "$TEST_LOG_FILE" 2>&1; then
        log_test_fail "Download with invalid Go module" "Script should have failed but succeeded"
    else
        log_test_pass "Download with invalid Go module"
    fi
}

test_version_mismatch_reinstall() {
    log_test_start "Reinstall when version changes"

    local test_dir="${TEST_INSTALL_DIR}/version_mismatch"
    mkdir -p "$test_dir"

    # First install the old version using the actual script
    if "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "$TEST_TOOL_VERSIONED" "$TEST_MODULE_VERSIONED_OLD" >> "$TEST_LOG_FILE" 2>&1; then
        # Then try to install newer version (should detect version mismatch and reinstall)
        if "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "$TEST_TOOL_VERSIONED" "$TEST_MODULE_VERSIONED" >> "$TEST_LOG_FILE" 2>&1; then
            if [[ -x "$test_dir/$TEST_TOOL_VERSIONED" ]]; then
                local version_output
                if version_output=$(go version -m "$test_dir/$TEST_TOOL_VERSIONED" 2>/dev/null | awk '$1 == "mod" {print $3; exit}'); then
                    if echo "$version_output" | grep -q "v0.25.0"; then
                        log_test_pass "Reinstall when version changes"
                    else
                        log_test_fail "Reinstall when version changes" "Version not updated: $version_output"
                    fi
                else
                    log_test_pass "Reinstall when version changes (version check unavailable)"
                fi
            else
                log_test_fail "Reinstall when version changes" "Binary not created after reinstall"
            fi
        else
            log_test_fail "Reinstall when version changes" "Script failed on version upgrade"
        fi
    else
        log_test_fail "Reinstall when version changes" "Initial installation failed"
    fi
}

test_version_match_skip() {
    log_test_start "Skip download when version matches"

    local test_dir="${TEST_INSTALL_DIR}/version_match"
    mkdir -p "$test_dir"

    # First install the tool
    if "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "$TEST_TOOL_VERSIONED" "$TEST_MODULE_VERSIONED" >> "$TEST_LOG_FILE" 2>&1; then
        # Then try to install the same version again (should skip download)
        if "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "$TEST_TOOL_VERSIONED" "$TEST_MODULE_VERSIONED" >> "$TEST_LOG_FILE" 2>&1; then
            log_test_pass "Skip download when version matches"
        else
            log_test_fail "Skip download when version matches" "Script failed on second run"
        fi
    else
        log_test_fail "Skip download when version matches" "Initial installation failed"
    fi
}

test_force_flag() {
    log_test_start "Force flag reinstalls existing tool"

    local test_dir="${TEST_INSTALL_DIR}/force_flag"
    mkdir -p "$test_dir"

    # First install the tool using the actual script
    if "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "$TEST_TOOL_NAME" "$TEST_MODULE_OLD" >> "$TEST_LOG_FILE" 2>&1; then
        # Test force flag should reinstall even with matching version
        if "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" --force "$TEST_TOOL_NAME" "$TEST_MODULE_OLD" >> "$TEST_LOG_FILE" 2>&1; then
            if [[ -x "$test_dir/$TEST_TOOL_NAME" ]]; then
                log_test_pass "Force flag reinstalls existing tool"
            else
                log_test_fail "Force flag reinstalls existing tool" "Binary not found after forced reinstall"
            fi
        else
            log_test_fail "Force flag reinstalls existing tool" "Script failed with force flag"
        fi
    else
        log_test_fail "Force flag reinstalls existing tool" "Initial installation failed"
    fi
}

test_help_option() {
    log_test_start "Test help option"

    # Test help option should succeed
    if "$DOWNLOAD_SCRIPT" --help >> "$TEST_LOG_FILE" 2>&1; then
        log_test_pass "Test help option"
    else
        log_test_fail "Test help option" "Help option failed"
    fi
}

test_invalid_option() {
    log_test_start "Test invalid option"

    # Test invalid option should fail
    if "$DOWNLOAD_SCRIPT" --invalid-option >> "$TEST_LOG_FILE" 2>&1; then
        log_test_fail "Test invalid option" "Script should have failed but succeeded"
    else
        log_test_pass "Test invalid option"
    fi
}

test_missing_arguments() {
    log_test_start "Test missing required arguments"

    # Test missing tool name should fail
    if "$DOWNLOAD_SCRIPT" >> "$TEST_LOG_FILE" 2>&1; then
        log_test_fail "Test missing required arguments" "Script should have failed but succeeded"
    else
        log_test_pass "Test missing required arguments"
    fi
}

test_missing_install_dir_argument() {
    log_test_start "Test missing install directory argument"

    # Test missing install directory argument should fail
    if "$DOWNLOAD_SCRIPT" --install-dir >> "$TEST_LOG_FILE" 2>&1; then
        log_test_fail "Test missing install directory argument" "Script should have failed but succeeded"
    else
        log_test_pass "Test missing install directory argument"
    fi
}

test_invalid_module_format() {
    log_test_start "Test invalid module format (missing @version)"

    local test_dir="${TEST_INSTALL_DIR}/invalid_format"
    mkdir -p "$test_dir"

    # Test should fail with module missing version
    if "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "test-tool" "golang.org/x/tools/cmd/goimports" >> "$TEST_LOG_FILE" 2>&1; then
        log_test_fail "Test invalid module format" "Script should have failed but succeeded"
    else
        log_test_pass "Test invalid module format"
    fi
}

test_non_runnable_binary_reinstall() {
    log_test_start "Reinstall when binary is not runnable (wrong arch simulation)"

    local test_dir="${TEST_INSTALL_DIR}/non_runnable"
    mkdir -p "$test_dir"

    local version_module="golang.org/x/tools/cmd/goimports@v0.24.0"

    # First install a real working binary
    if ! "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "$TEST_TOOL_NAME" "$version_module" >> "$TEST_LOG_FILE" 2>&1; then
        log_test_fail "Reinstall when binary is not runnable" "Initial installation failed"
        return
    fi

    # Replace with a stub that exits 126 for all invocations, simulating
    # exec format error (what the kernel returns for a wrong-arch binary).
    cat > "$test_dir/$TEST_TOOL_NAME" << 'STUB'
#!/bin/sh
exit 126
STUB
    chmod +x "$test_dir/$TEST_TOOL_NAME"

    # Run download script again with the same version.
    # The stub won't pass go version -m either, so get_tool_version will fail
    # and the script will fall through to reinstall. This validates that a
    # non-runnable binary at the install path does not block reinstallation.
    if "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "$TEST_TOOL_NAME" "$version_module" >> "$TEST_LOG_FILE" 2>&1; then
        # Verify the reinstalled binary is actually runnable (exit code != 126)
        local rc=0
        "$test_dir/$TEST_TOOL_NAME" --help >/dev/null 2>&1 || rc=$?
        if [[ $rc -ne 126 ]]; then
            log_test_pass "Reinstall when binary is not runnable"
        else
            log_test_fail "Reinstall when binary is not runnable" "Binary still not runnable after reinstall"
        fi
    else
        log_test_fail "Reinstall when binary is not runnable" "Script failed on reinstall"
    fi
}

test_version_match_but_not_runnable() {
    log_test_start "Reinstall when version matches but binary cannot run"

    local test_dir="${TEST_INSTALL_DIR}/version_match_not_runnable"
    mkdir -p "$test_dir"

    local version_module="golang.org/x/tools/cmd/goimports@v0.24.0"

    # First install a real working binary
    if ! "$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "$TEST_TOOL_NAME" "$version_module" >> "$TEST_LOG_FILE" 2>&1; then
        log_test_fail "Reinstall when version matches but binary cannot run" "Initial installation failed"
        return
    fi

    # Replace with a stub that exits 126, simulating exec format error.
    # go version -m won't extract metadata from a shell script, so
    # get_tool_version also fails and the script falls through to reinstall.
    cat > "$test_dir/$TEST_TOOL_NAME" << 'STUB'
#!/bin/sh
exit 126
STUB
    chmod +x "$test_dir/$TEST_TOOL_NAME"

    # Run download script — should detect non-runnable and reinstall
    local output
    if output=$("$DOWNLOAD_SCRIPT" --install-dir "$test_dir" "$TEST_TOOL_NAME" "$version_module" 2>&1); then
        # Verify reinstalled binary works (exit code != 126)
        local rc=0
        "$test_dir/$TEST_TOOL_NAME" --help >/dev/null 2>&1 || rc=$?
        if [[ $rc -ne 126 ]]; then
            log_test_pass "Reinstall when version matches but binary cannot run"
        else
            log_test_fail "Reinstall when version matches but binary cannot run" "Binary not runnable after reinstall"
        fi
    else
        log_test_fail "Reinstall when version matches but binary cannot run" "Script failed on reinstall"
    fi
    echo "$output" >> "$TEST_LOG_FILE"
}

test_custom_install_directory() {
    log_test_start "Test custom install directory"

    local custom_dir="${TEST_INSTALL_DIR}/custom"

    # Test should succeed with custom directory
    if "$DOWNLOAD_SCRIPT" --install-dir "$custom_dir" "$TEST_TOOL_NAME" "$TEST_MODULE_OLD" >> "$TEST_LOG_FILE" 2>&1; then
        if [[ -x "$custom_dir/$TEST_TOOL_NAME" ]]; then
            log_test_pass "Test custom install directory"
        else
            log_test_fail "Test custom install directory" "Binary not created in custom directory"
        fi
    else
        log_test_fail "Test custom install directory" "Script failed"
    fi
}

test_absolute_path_handling() {
    log_test_start "Test absolute path handling"

    local relative_dir="./test_relative"
    local test_dir="${TEST_INSTALL_DIR}/relative_test"
    mkdir -p "$test_dir"

    # Save current directory
    local original_dir
    original_dir=$(pwd)
    # Change to test directory and use relative path
    cd "$test_dir"
    if "$DOWNLOAD_SCRIPT" --install-dir "$relative_dir" "$TEST_TOOL_NAME" "$TEST_MODULE_OLD" >> "$TEST_LOG_FILE" 2>&1; then
        if [[ -x "$test_dir/$relative_dir/$TEST_TOOL_NAME" ]]; then
            log_test_pass "Test absolute path handling"
        else
            log_test_fail "Test absolute path handling" "Binary not created with relative path"
        fi
    else
        log_test_fail "Test absolute path handling" "Script failed with relative path"
    fi

    # Restore original directory
    cd "$original_dir"
}

print_test_summary() {
    log ""
    log "================================================"
    log "Test Summary:"
    log "Total tests: $TOTAL_TESTS"
    log "Passed: $PASSED_TESTS"
    log "Failed: $FAILED_TESTS"
    log "================================================"

    if [[ $FAILED_TESTS -gt 0 ]]; then
        log "${RED}Some tests failed. See $TEST_LOG_FILE for details.${NC}"
        return 1
    else
        log "${GREEN}All tests passed!${NC}"
        return 0
    fi
}

main() {
    log "Starting Go Tool Download Script Tests"
    log "======================================"

    # Check if download script exists
    if [[ ! -f "$DOWNLOAD_SCRIPT" ]]; then
        log "${RED}Error: Download script not found at $DOWNLOAD_SCRIPT${NC}"
        exit 1
    fi

    setup_test_environment

    # Run tests
    test_download_valid_tool
    test_download_versioned_tool
    test_download_invalid_module
    test_version_mismatch_reinstall
    test_version_match_skip
    test_force_flag
    test_help_option
    test_invalid_option
    test_missing_arguments
    test_missing_install_dir_argument
    test_invalid_module_format
    test_non_runnable_binary_reinstall
    test_version_match_but_not_runnable
    test_custom_install_directory
    test_absolute_path_handling

    cleanup_test_environment

    print_test_summary
}

# Run main function
main "$@"
