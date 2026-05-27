#!/usr/bin/env bash

# Automates the generation of an RPM lock file for a RHEL 9 image.
# This script operates on a single target directory, which must contain
# an 'rpms.in.yaml' file. The image to lock can be provided via the
# RHEL9_IMAGE_TO_LOCK environment variable, otherwise it defaults to the execution image.
#
# Usage: ./generate-rhel9-locks.sh [PATH_TO_TARGET_DIR]
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)"

# --- Configuration ---
RHEL9_RELEASE="${RHEL9_RELEASE:-latest}"

# The image used to RUN the container, which needs subscription-manager and other tools.
RHEL9_EXECUTION_IMAGE="${RHEL9_EXECUTION_IMAGE:-registry.access.redhat.com/ubi9/ubi:${RHEL9_RELEASE}}"

# The image to generate the lock file FOR. Defaults to the execution image if not set.
RHEL9_IMAGE_TO_LOCK="${RHEL9_IMAGE_TO_LOCK:-${RHEL9_EXECUTION_IMAGE}}"

# Use environment variables for credentials if set, otherwise prompt for input
RHEL9_ACTIVATION_KEY="${RHEL9_ACTIVATION_KEY:-}"
RHEL9_ORG_ID="${RHEL9_ORG_ID:-}"

# The version of rpm-lockfile-prototype to use. Defaults to main.
RPM_LOCKFILE_PROTOTYPE_VERSION="${RPM_LOCKFILE_PROTOTYPE_VERSION:-main}"

# The registry auth file is mounted into the container to allow for private registry pulls.
# This is automatically detected and mounted into the container if it exists on the host.
# If it does not exist, a warning is printed and the registry pulls may fail if not public.
# This can be set from the command line if the default is not correct for your environment.
REGISTRY_AUTH_FILE="${REGISTRY_AUTH_FILE:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json}"

# Use the first argument as the target directory.
readonly LOCK_SCRIPT_TARGET_DIR="${1:-${SCRIPT_DIR}}"

# --- Main Script ---
# Step 1: Validate configuration
if [[ ! -d "${LOCK_SCRIPT_TARGET_DIR}" ]]; then
    echo "ERROR: Target directory not found at '${LOCK_SCRIPT_TARGET_DIR}'." >&2
    exit 1
fi
# Resolve to an absolute path for the podman mount
readonly ABS_PROJECT_DIR="$(cd "${LOCK_SCRIPT_TARGET_DIR}" && pwd)"

# Step 2: Check for podman
if ! command -v podman &> /dev/null; then
    echo "ERROR: podman could not be found. Please install it." >&2
    exit 1
fi

# Step 3: Check credentials and determine if RHSM registration should be used
if [[ -z "$RHEL9_ORG_ID" || -z "$RHEL9_ACTIVATION_KEY" ]]; then
    echo "RHEL 9 credentials not provided or are placeholder values. Skipping RHSM registration."
    echo "Using UBI repositories only for lock file generation."
    USE_RHSM=false
else
    echo "RHEL 9 credentials provided. Will use RHSM registration for enhanced repositories."
    USE_RHSM=true
fi

# Step 4: Validate existence of input file
if [[ ! -f "${ABS_PROJECT_DIR}/rpms.in.yaml" ]]; then
    echo "ERROR: Input file not found at '${ABS_PROJECT_DIR}/rpms.in.yaml'." >&2
    exit 1
fi

# Extra podman run arguments: registry auth mount (if present) and OS-specific flags.
PODMAN_RUN_ARGS=()
if [ -f "${REGISTRY_AUTH_FILE}" ]; then
    echo "Found Podman auth file at ${REGISTRY_AUTH_FILE}. Mounting into container."
    PODMAN_RUN_ARGS+=(-v "${REGISTRY_AUTH_FILE}:/root/.config/containers/auth.json:Z")
fi
case "$(uname -s)" in
    Linux)
        echo "Linux detected. Using --tmpfs /run/secrets."
        PODMAN_RUN_ARGS+=(--tmpfs /run/secrets)
        ;;
    Darwin)
        echo "macOS detected. Using --platform=linux/amd64 and --tmpfs /run/secrets."
        PODMAN_RUN_ARGS+=(--platform=linux/amd64 --tmpfs /run/secrets)
        ;;
    *)
        echo "Warning: Unsupported OS '$(uname -s)'. Proceeding without OS-specific flags."
        ;;
esac

# Step 6: Create a temporary script file to be run inside the container.
readonly SCRIPT_FILE_PATH="${ABS_PROJECT_DIR}/podman_script.sh"
trap 'rm -f "${SCRIPT_FILE_PATH}"' EXIT

cat > "${SCRIPT_FILE_PATH}" <<EOF
#!/usr/bin/env bash
set -eux

# Copy input file to output file for modifications
echo "STEP 1: Copying rpms.in.yaml to rpms.out.yaml..."
cp /source/rpms.in.yaml /source/rpms.out.yaml

# Helper function to extract repository IDs from rpms.out.yaml
extract_repo_ids() {
    if [ -f "/source/rpms.out.yaml" ]; then
        # Extract repoid values from the YAML file
        grep -E '^[[:space:]]*-[[:space:]]*repoid:' /source/rpms.out.yaml | \
            sed 's/^[[:space:]]*-[[:space:]]*repoid:[[:space:]]*//' | \
            tr -d '"'"'"
    fi
}

if [ "${USE_RHSM}" = "true" ]; then
    echo "STEP 2: Registering system..."
    subscription-manager register --org "${RHEL9_ORG_ID}" --activationkey "${RHEL9_ACTIVATION_KEY}" --force
    if [ "${RHEL9_RELEASE}" != "latest" ]; then
        echo "Setting RHEL 9 release to ${RHEL9_RELEASE}"
        subscription-manager release --set="${RHEL9_RELEASE}"
    else
        echo "Using latest RHEL 9 release"
    fi

    subscription-manager refresh

    # Disable all repositories and enable only what we need for skopeo and python3-pip
    echo "Disabling all repositories..."
    subscription-manager repos --disable="*" || echo "Could not disable all repositories"

    echo "Enabling minimal repositories for skopeo and python3-pip..."
    subscription-manager repos --enable="rhel-9-for-x86_64-baseos-rpms" || echo "Could not enable rhel-9-for-x86_64-baseos-rpms"
    subscription-manager repos --enable="rhel-9-for-x86_64-appstream-rpms" || echo "Could not enable rhel-9-for-x86_64-appstream-rpms"

    echo "STEP 3: RHSM registration complete..."
    # Note: Repository configuration for the lock file will be handled by rpm-lockfile-prototype
    # which reads repository definitions directly from rpms.in.yaml
    # This is separate from the repository configuration for this runtime container.
    REPO_IDS=\$(extract_repo_ids)

    if [ -n "\$REPO_IDS" ]; then
        echo "Repository configuration found in rpms.in.yaml (will be used by rpm-lockfile-prototype):"
        while IFS= read -r repo_id; do
            if [ -n "\$repo_id" ]; then
                echo "  - \$repo_id"
            fi
        done <<< "\$REPO_IDS"
    else
        echo "No specific repository configuration found in rpms.in.yaml."
    fi

    echo "STEP 4: Updating SSL certificate paths in rpms.out.yaml..."
    # Find the actual certificate files created by RHSM registration
    CERT_FILE=\$(find /etc/pki/entitlement/ -type f -name "*.pem" ! -name "*-key.pem" | head -1)
    KEY_FILE=\$(find /etc/pki/entitlement/ -type f -name "*-key.pem" | head -1)

    if [ -n "\$CERT_FILE" ] && [ -n "\$KEY_FILE" ]; then
        echo "Found certificates: \$CERT_FILE and \$KEY_FILE"
        # Update rpms.out.yaml with the actual certificate paths
        # Handle both sslclientcert and sslclientkey patterns
        sed -i "s|sslclientcert: /etc/pki/entitlement/[^[:space:]]*\.pem|sslclientcert: \$CERT_FILE|g" /source/rpms.out.yaml
        sed -i "s|sslclientkey: /etc/pki/entitlement/[^[:space:]]*-key\.pem|sslclientkey: \$KEY_FILE|g" /source/rpms.out.yaml

        # Also update any repository file that might have been generated
        if [ -f "/source/redhat.repo" ]; then
            sed -i "s|^sslclientcert.*|sslclientcert = \$CERT_FILE|" /source/redhat.repo
            sed -i "s|^sslclientkey.*|sslclientkey = \$KEY_FILE|" /source/redhat.repo
        fi
    else
        echo "WARNING: Could not find entitlement certificates"
    fi

else
    echo "STEP 2: Skipping RHSM registration..."
    echo "Will use UBI repositories and configure based on rpms.in.yaml"
fi

echo "STEP 3: Repository configuration..."
# Note: rpm-lockfile-prototype reads repository definitions directly from rpms.in.yaml
# and adds them dynamically, so we don't need to configure repositories in the container
REPO_IDS=\$(extract_repo_ids)

if [ -n "\$REPO_IDS" ]; then
    echo "Repository configuration found in rpms.in.yaml (will be used by rpm-lockfile-prototype):"
    while IFS= read -r repo_id; do
        if [ -n "\$repo_id" ]; then
            echo "  - \$repo_id"
        fi
    done <<< "\$REPO_IDS"
else
    echo "No specific repository configuration found in rpms.in.yaml."
fi

if [ "${USE_RHSM}" = "true" ]; then
    echo "RHSM mode: Using subscription-based repositories for certificate access."
else
    echo "UBI mode: Using public UBI repositories."
    echo "Available container repositories:"
    dnf repolist --enabled || true
fi

echo "STEP 4: Creating repository configuration file for output..."
# Copy the final repository configuration for output
cp /etc/yum.repos.d/redhat.repo /source/redhat.repo 2>/dev/null || echo "# No redhat.repo found" > /source/redhat.repo

echo "STEP 5: Installing tools (skopeo, python3-pip)..."
dnf install -y skopeo python3-pip

echo "STEP 6: Installing rpm-lockfile-prototype tool..."
echo "Using version: ${RPM_LOCKFILE_PROTOTYPE_VERSION}"
python3 -m pip install --user "https://github.com/konflux-ci/rpm-lockfile-prototype/archive/${RPM_LOCKFILE_PROTOTYPE_VERSION}.zip" &>/dev/null

echo "STEP 7: Generating lock file for image: ${RHEL9_IMAGE_TO_LOCK}"
/root/.local/bin/rpm-lockfile-prototype \
    --image "${RHEL9_IMAGE_TO_LOCK}" \
    --outfile="/source/rpms.lock.yaml" \
    /source/rpms.out.yaml

echo "Lock file generation complete inside the container."
EOF

# Ensure the temporary script is executable
chmod +x "${SCRIPT_FILE_PATH}"

# --- Execution ---
echo -e "\n--- Starting RHEL 9 Lock File Generation for '${ABS_PROJECT_DIR}' ---"
echo "Using execution image: ${RHEL9_EXECUTION_IMAGE}"
echo "PREREQUISITE: You must be logged into registry.redhat.io via 'podman login'."
echo "----------------------------------------------"

podman run --rm -it "${PODMAN_RUN_ARGS[@]}" -v "${ABS_PROJECT_DIR}:/source:Z" --entrypoint /source/podman_script.sh "${RHEL9_EXECUTION_IMAGE}"

echo -e "\n--- Success! ---"
echo "Generated files are located in '${ABS_PROJECT_DIR}'."
echo "Please review and commit the following files:"
echo "  - redhat.repo"
echo "  - rpms.out.yaml (modified input file with runtime changes)"
echo "  - rpms.lock.yaml"
echo "--------------------"
