#!/bin/bash

# Source the common test library
# shellcheck source=test/overlay/common-test-lib.sh
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source "${SCRIPT_DIR}"/../../common-test-lib.sh

# Initialize debug mode from command line argument
init_debug_mode "${1:-}"

# Run the CSV overlay test for cluster-group-upgrades-operator
run_csv_overlay_test "cluster-group-upgrades-operator" "cluster-group-upgrades-operator CSV overlay test" "00.data"
