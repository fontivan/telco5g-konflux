#!/usr/bin/env bash

# Automates the UBI8 lock file workaround. This script uses a two-stage
# process against a single target directory, which must contain 'rpms.in.yaml'.
# The image to lock can be provided via the IMAGE_TO_LOCK environment variable,
# otherwise it defaults to the UBI8 execution image.
#
# Usage: ./generate-ubi8-locks.sh [PATH_TO_TARGET_DIR]
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)"

# --- Configuration ---
UBI8_RELEASE="${UBI8_RELEASE:-8.10}"
UBI9_RELEASE="${UBI9_RELEASE:-9.4}"

# The images used to RUN the containers, which need subscription-manager.
UBI8_EXECUTION_IMAGE="${UBI8_EXECUTION_IMAGE:-registry.redhat.io/ubi8/ubi:${UBI8_RELEASE}}"
UBI9_EXECUTION_IMAGE="${UBI9_EXECUTION_IMAGE:-registry.redhat.io/ubi9/ubi:${UBI9_RELEASE}}"

# The image to generate the lock file FOR. Defaults to the UBI8 execution image if not set.
IMAGE_TO_LOCK="${IMAGE_TO_LOCK:-${UBI8_EXECUTION_IMAGE}}"

# Use environment variables for credentials if set, otherwise prompt for input
RHEL8_ACTIVATION_KEY="${RHEL8_ACTIVATION_KEY:-}"
RHEL8_ORG_ID="${RHEL8_ORG_ID:-}"
RHEL9_ACTIVATION_KEY="${RHEL9_ACTIVATION_KEY:-}"
RHEL9_ORG_ID="${RHEL9_ORG_ID:-}"

# The registry auth file is mounted into the container to allow for private registry pulls.
# This is automatically detected and mounted into the container if it exists on the host.
# If it does not exist, a warning is printed and the registry pulls may fail if not public.
# This can be set from the command line if the default is not correct for your environment.
REGISTRY_AUTH_FILE="${REGISTRY_AUTH_FILE:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json}"

# Mount the registry auth file into the container if it exists.
AUTH_MOUNT_FLAG=""

# If the registry auth file is not set, use the default path.
if [ -f "${REGISTRY_AUTH_FILE}" ]; then
    echo "Found Podman auth file at ${REGISTRY_AUTH_FILE}. Mounting into container."
    AUTH_MOUNT_FLAG="-v ${REGISTRY_AUTH_FILE}:/root/.config/containers/auth.json:Z"
fi

# Use the first argument as the target directory.
readonly LOCK_SCRIPT_TARGET_DIR="${1:-${SCRIPT_DIR}}"
readonly RHEL8_REPO_FILE="redhat-rhel8.repo.generated"

# --- Main Script ---
# 0. Validate configuration
if [[ ! -d "${LOCK_SCRIPT_TARGET_DIR}" ]]; then
    echo "ERROR: Target directory not found at '${LOCK_SCRIPT_TARGET_DIR}'." >&2
    exit 1
fi
# Resolve to an absolute path for the podman mount
readonly ABS_PROJECT_DIR="$(cd "${LOCK_SCRIPT_TARGET_DIR}" && pwd)"

# 1. Check for podman
if ! command -v podman &> /dev/null; then
    echo "ERROR: podman could not be found. Please install it." >&2
    exit 1
fi

# --- Part 1: Generate RHEL 8 Repo File ---
echo "--- Part 1: Generating RHEL 8 Repository File ---"
if [[ -z "$RHEL8_ORG_ID" || -z "$RHEL8_ACTIVATION_KEY" ]]; then
    echo ""
    read -p "Enter your RHEL 8-enabled Organization ID: " RHEL8_ORG_ID
    read -s -p "Enter your RHEL 8-enabled Activation Key: " RHEL8_ACTIVATION_KEY
    echo ""
fi

if [[ -z "$RHEL8_ORG_ID" || -z "$RHEL8_ACTIVATION_KEY" ]]; then
    echo "ERROR: RHEL 8 credentials cannot be empty." >&2
    exit 1
fi

# Generate the repo file in a temporary location within the target directory
readonly TEMP_REPO_FILE_PATH="${ABS_PROJECT_DIR}/${RHEL8_REPO_FILE}"
trap 'rm -f "${TEMP_REPO_FILE_PATH}"' EXIT

read -r -d '' UBI8_COMMANDS <<EOF
set -eux
echo "[UBI8] Registering system to RHEL 8..."
subscription-manager register --org "${RHEL8_ORG_ID}" --activationkey "${RHEL8_ACTIVATION_KEY}" --force
subscription-manager release --set="${UBI8_RELEASE}"
subscription-manager refresh
echo "[UBI8] Copying generated repo file to /source..."
cp /etc/yum.repos.d/redhat.repo "/source/${RHEL8_REPO_FILE}"
echo "[UBI8] Process complete."
EOF

echo "Running UBI8 container to extract RHEL 8 repo file into '${ABS_PROJECT_DIR}'..."
echo "Using UBI8 execution image: ${UBI8_EXECUTION_IMAGE}"
podman run --rm -it ${AUTH_MOUNT_FLAG} -v "${ABS_PROJECT_DIR}:/source:Z" --entrypoint sh "${UBI8_EXECUTION_IMAGE}" -c "${UBI8_COMMANDS}"

if [ ! -f "${TEMP_REPO_FILE_PATH}" ]; then
    echo "ERROR: Failed to generate RHEL 8 repo file." >&2
    exit 1
fi
echo "Successfully generated '${TEMP_REPO_FILE_PATH}'"
echo "----------------------------------------------------"

# --- Part 2: Generate Lock Files using UBI 9 Container ---
echo -e "\n--- Part 2: Generating Lock Files using UBI 9 ---"
if [[ -z "$RHEL9_ORG_ID" || -z "$RHEL9_ACTIVATION_KEY" ]]; then
    echo ""
    read -p "Enter your RHEL 9-enabled Organization ID: " RHEL9_ORG_ID
    read -s -p "Enter your RHEL 9-enabled Activation Key: " RHEL9_ACTIVATION_KEY
    echo ""
fi

if [[ -z "$RHEL9_ORG_ID" || -z "$RHEL9_ACTIVATION_KEY" ]]; then
    echo "ERROR: RHEL 9 credentials cannot be empty." >&2
    exit 1
fi

# Validate existence of input file
if [[ ! -f "${ABS_PROJECT_DIR}/rpms.in.yaml" ]]; then
    echo "ERROR: Input file not found at '${ABS_PROJECT_DIR}/rpms.in.yaml'." >&2
    exit 1
fi

# Determine if multi-arch patch is needed by checking for an 'arches' key in the input file.
APPLY_MULTI_ARCH_PATCH="false"
if grep -q "^arches:" "${ABS_PROJECT_DIR}/rpms.in.yaml"; then
    echo "Multi-arch build detected from 'arches' key in rpms.in.yaml."
    APPLY_MULTI_ARCH_PATCH="true"
else
    echo "Single-arch build detected."
fi

# Create a temporary script file to be run inside the UBI9 container.
readonly SCRIPT_FILE_PATH="${ABS_PROJECT_DIR}/podman_script_ubi9.sh"
trap 'rm -f "${TEMP_REPO_FILE_PATH}" "${SCRIPT_FILE_PATH}"' EXIT

cat > "${SCRIPT_FILE_PATH}" <<EOF
#!/usr/bin/env bash
set -eux

echo "[UBI9] Registering system to RHEL 9 to get valid certs..."
subscription-manager register --org "${RHEL9_ORG_ID}" --activationkey "${RHEL9_ACTIVATION_KEY}" --force
subscription-manager release --set="${UBI9_RELEASE}"
subscription-manager refresh

echo "[UBI9] Finding RHEL 9 entitlement certificates..."
CERT_FILE=\$(find /etc/pki/entitlement/ -type f -name "*.pem" ! -name "*-key.pem")
KEY_FILE=\$(find /etc/pki/entitlement/ -type f -name "*-key.pem")

echo "[UBI9] Modifying the RHEL 8 repo file with RHEL 9 certificates..."
# The temporary repo file is copied to the final name 'redhat.repo'
cp "/source/${RHEL8_REPO_FILE}" /source/redhat.repo
sed -i "s|^sslclientcert.*|sslclientcert = \${CERT_FILE}|" "/source/redhat.repo"
sed -i "s|^sslclientkey.*|sslclientkey = \${KEY_FILE}|" "/source/redhat.repo"

echo "[UBI9] Installing tools..."
dnf install -y python3-pip &>/dev/null
python3 -m pip install --user https://github.com/konflux-ci/rpm-lockfile-prototype/archive/refs/heads/main.zip &>/dev/null

if [ "${APPLY_MULTI_ARCH_PATCH}" = "true" ]; then
    echo '[UBI9] Applying multi-arch patch to repo file...'
    sed -i "s/\$(uname -m)/\\\$basearch/g" /source/redhat.repo
fi

echo "[UBI9] Generating lock file for image: ${IMAGE_TO_LOCK}"
/root/.local/bin/rpm-lockfile-prototype \
    --repo-file="/source/redhat.repo" \
    --image "${IMAGE_TO_LOCK}" \
    --outfile="/source/rpms.lock.yaml" \
    /source/rpms.in.yaml

echo "[UBI9] Lock file generation complete."
EOF

# Ensure the temporary script is executable
chmod +x "${SCRIPT_FILE_PATH}"

echo "Running UBI9 container to perform certificate swap and generate lock files..."
echo "Using UBI9 execution image: ${UBI9_EXECUTION_IMAGE}"
podman run --rm -it ${AUTH_MOUNT_FLAG} -v "${ABS_PROJECT_DIR}:/source:Z" --entrypoint /source/podman_script_ubi9.sh "${UBI9_EXECUTION_IMAGE}"

echo -e "\n--- Success! ---"
echo "Generated files for UBI8 are located in '${ABS_PROJECT_DIR}'."
echo "Please review and commit the following files:"
echo "  - redhat.repo"
echo "  - rpms.lock.yaml"
echo "--------------------"
