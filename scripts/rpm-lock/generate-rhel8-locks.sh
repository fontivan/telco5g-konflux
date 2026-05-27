#!/usr/bin/env bash

# Automates the RHEL 8 lock file generation. This script uses a two-stage
# process against a single target directory, which must contain 'rpms.in.yaml'.
# The image to lock can be provided via the RHEL8_IMAGE_TO_LOCK environment variable,
# otherwise it defaults to the UBI8 execution image.
#
# Usage: ./generate-rhel8-locks.sh [PATH_TO_TARGET_DIR]
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd)"

# --- Configuration ---
RHEL8_RELEASE="${RHEL8_RELEASE:-latest}"
RHEL9_RELEASE="${RHEL9_RELEASE:-latest}"

# The images used to RUN the containers, which need subscription-manager.
RHEL8_EXECUTION_IMAGE="${RHEL8_EXECUTION_IMAGE:-registry.access.redhat.com/ubi8/ubi:${RHEL8_RELEASE}}"
RHEL9_EXECUTION_IMAGE="${RHEL9_EXECUTION_IMAGE:-registry.access.redhat.com/ubi9/ubi:${RHEL9_RELEASE}}"

# The image to generate the lock file FOR. Defaults to the UBI8 execution image if not set.
RHEL8_IMAGE_TO_LOCK="${RHEL8_IMAGE_TO_LOCK:-${RHEL8_EXECUTION_IMAGE}}"

# Use environment variables for credentials if set, otherwise prompt for input
RHEL8_ACTIVATION_KEY="${RHEL8_ACTIVATION_KEY:-}"
RHEL8_ORG_ID="${RHEL8_ORG_ID:-}"
RHEL9_ACTIVATION_KEY="${RHEL9_ACTIVATION_KEY:-}"
RHEL9_ORG_ID="${RHEL9_ORG_ID:-}"

# The version of rpm-lockfile-prototype to use. Defaults to main.
RPM_LOCKFILE_PROTOTYPE_VERSION="${RPM_LOCKFILE_PROTOTYPE_VERSION:-main}"

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

# Mask auto-mounted RHSM secrets (Podman Desktop, entitled hosts) so
# subscription-manager can register inside the container when needed.
PODMAN_FLAGS=""
case "$(uname -s)" in
    Linux)
        echo "Linux detected. Using --tmpfs /run/secrets."
        PODMAN_FLAGS="--tmpfs /run/secrets"
        ;;
    Darwin)
        echo "macOS detected. Using --platform=linux/amd64 and --tmpfs /run/secrets."
        PODMAN_FLAGS="--platform=linux/amd64 --tmpfs /run/secrets"
        ;;
    *)
        echo "Warning: Unsupported OS '$(uname -s)'. Proceeding without OS-specific flags."
        ;;
esac

# --- Step 3: Generate RHEL 8 Repo File ---
echo "--- Step 3: Generating RHEL 8 Repository File ---"

# Check if credentials are empty, placeholder values, or not provided
if [[ -z "$RHEL8_ORG_ID" || -z "$RHEL8_ACTIVATION_KEY" ]]; then
    echo "RHEL 8 credentials not provided or are placeholder values. Skipping RHSM registration."
else
    echo "RHEL 8 credentials provided. Proceeding with RHSM registration."

    RHEL8_COMMANDS=$(cat <<EOF
set -eux

# Copy input file to output file for modifications
echo "STEP 1: Copying rpms.in.yaml to rpms.out.yaml..."
cp /source/rpms.in.yaml /source/rpms.out.yaml

# Helper function to extract repository IDs from rpms.out.yaml
extract_repo_ids() {
    if [ -f "/source/rpms.out.yaml" ]; then
        # Extract repoid values from the YAML file
        grep -E '^[[:space:]]*-[[:space:]]*repoid:' /source/rpms.out.yaml | \\
            sed 's/^[[:space:]]*-[[:space:]]*repoid:[[:space:]]*//' | \\
            tr -d '"'"'"
    fi
}

echo "STEP 2: Registering system to RHEL 8..."
subscription-manager register --org "${RHEL8_ORG_ID}" --activationkey "${RHEL8_ACTIVATION_KEY}" --force
if [ "${RHEL8_RELEASE}" != "latest" ]; then
    echo "Setting RHEL 8 release to ${RHEL8_RELEASE}"
    subscription-manager release --set="${RHEL8_RELEASE}"
else
    echo "Using latest RHEL 8 release"
fi

subscription-manager refresh

# Disable all repositories and enable only what we need for skopeo and python3-pip
echo "Disabling all repositories..."
subscription-manager repos --disable="*" || echo "Could not disable all repositories"

echo "Enabling minimal repositories for skopeo and python3-pip..."
subscription-manager repos --enable="rhel-8-for-x86_64-baseos-rpms" || echo "Could not enable rhel-8-for-x86_64-baseos-rpms"
subscription-manager repos --enable="rhel-8-for-x86_64-appstream-rpms" || echo "Could not enable rhel-8-for-x86_64-appstream-rpms"

# Configure repositories based on rpms.in.yaml if it exists
REPO_IDS=\$(extract_repo_ids)

echo "STEP 3: RHEL 8 RHSM registration complete..."
# Note: Repository configuration for the lock file will be handled by rpm-lockfile-prototype
# which reads repository definitions directly from rpms.in.yaml
# This is separate from the repository configuration for this runtime container.
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

echo "STEP 4: Copying generated repo file to /source..."
cp /etc/yum.repos.d/redhat.repo "/source/${RHEL8_REPO_FILE}"
echo "Process complete."
EOF
)

    echo "Running container to extract RHEL 8 repo file into '${ABS_PROJECT_DIR}'..."
    echo "Using execution image: ${RHEL8_EXECUTION_IMAGE}"
    podman run --rm -it ${AUTH_MOUNT_FLAG} ${PODMAN_FLAGS} -v "${ABS_PROJECT_DIR}:/source:Z" --entrypoint sh "${RHEL8_EXECUTION_IMAGE}" -c "${RHEL8_COMMANDS}"

    if [ ! -f "${ABS_PROJECT_DIR}/${RHEL8_REPO_FILE}" ]; then
        echo "ERROR: Failed to generate RHEL 8 repo file." >&2
        exit 1
    fi
    echo "Successfully generated '${ABS_PROJECT_DIR}/${RHEL8_REPO_FILE}'"
fi
echo "----------------------------------------------------"

# --- Step 4: Generate Lock Files using UBI 9 Container ---
echo -e "\n--- Step 4: Generating Lock Files using UBI 9 ---"

# Check if RHEL9 credentials are empty, placeholder values, or not provided
if [[ -z "$RHEL9_ORG_ID" || -z "$RHEL9_ACTIVATION_KEY" || "$RHEL9_ORG_ID" == "placeholder" || "$RHEL9_ACTIVATION_KEY" == "placeholder" || "$RHEL9_ORG_ID" == "1234567890" ]]; then
    echo "RHEL 9 credentials not provided or are placeholder values. Skipping RHSM registration."
    echo "Using UBI repositories only for lock file generation."
    USE_RHSM_RHEL9=false

    # Convert registry.redhat.io URLs to registry.access.redhat.com for public access
    if [[ "${RHEL8_IMAGE_TO_LOCK}" == *"registry.redhat.io"* ]]; then
        PUBLIC_RHEL8_IMAGE_TO_LOCK=$(echo "${RHEL8_IMAGE_TO_LOCK}" | sed 's|registry\.redhat\.io|registry.access.redhat.com|g')
        echo "Converting image URL for public access: ${RHEL8_IMAGE_TO_LOCK} -> ${PUBLIC_RHEL8_IMAGE_TO_LOCK}"
        RHEL8_IMAGE_TO_LOCK="${PUBLIC_RHEL8_IMAGE_TO_LOCK}"
    fi
else
    echo "RHEL 9 credentials provided. Will use RHSM registration for enhanced repositories."
    USE_RHSM_RHEL9=true
fi

# Validate existence of input file
if [[ ! -f "${ABS_PROJECT_DIR}/rpms.in.yaml" ]]; then
    echo "ERROR: Input file not found at '${ABS_PROJECT_DIR}/rpms.in.yaml'." >&2
    exit 1
fi

# Create a temporary script file to be run inside the UBI9 container.
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

if [ "${USE_RHSM_RHEL9}" = "true" ]; then
    echo "STEP 2: Registering system to RHEL 9 to get valid certs..."
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

    # Configure repositories based on rpms.in.yaml if it exists
    REPO_IDS=\$(extract_repo_ids)

    echo "STEP 3: RHEL 9 RHSM registration complete..."
    # Note: Repository configuration for the lock file will be handled by rpm-lockfile-prototype
    # which reads repository definitions directly from rpms.in.yaml
    # This is separate from the repository configuration for this runtime container.
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

    echo "STEP 4: Finding RHEL 9 entitlement certificates and updating repo file..."
    CERT_FILE=\$(find /etc/pki/entitlement/ -type f -name "*.pem" ! -name "*-key.pem" | head -1)
    KEY_FILE=\$(find /etc/pki/entitlement/ -type f -name "*-key.pem" | head -1)

    echo "Modifying the RHEL 8 repo file with RHEL 9 certificates..."
    # The temporary repo file is copied to the final name 'redhat.repo'
    cp "/source/${RHEL8_REPO_FILE}" /source/redhat.repo

    if [ -n "\$CERT_FILE" ] && [ -n "\$KEY_FILE" ]; then
        echo "Found certificates: \$CERT_FILE and \$KEY_FILE"
        sed -i "s|^sslclientcert.*|sslclientcert = \$CERT_FILE|" "/source/redhat.repo"
        sed -i "s|^sslclientkey.*|sslclientkey = \$KEY_FILE|" "/source/redhat.repo"

        # Also update rpms.out.yaml with the actual certificate paths
        echo "Updating SSL certificate paths in rpms.out.yaml..."
        sed -i "s|sslclientcert: /etc/pki/entitlement/[^[:space:]]*\.pem|sslclientcert: \$CERT_FILE|g" /source/rpms.out.yaml
        sed -i "s|sslclientkey: /etc/pki/entitlement/[^[:space:]]*-key\.pem|sslclientkey: \$KEY_FILE|g" /source/rpms.out.yaml
    else
        echo "WARNING: Could not find entitlement certificates"
    fi
else
    echo "STEP 2: Skipping RHSM registration. Using UBI repositories..."
    # No need to copy a repo file - UBI images have repositories pre-configured
    # We'll configure repositories using dnf/yum commands based on rpms.in.yaml
fi

echo "STEP 5: Installing tools..."
dnf install -y skopeo python3-pip &>/dev/null

echo "STEP 6: Installing rpm-lockfile-prototype tool..."
echo "Using version: ${RPM_LOCKFILE_PROTOTYPE_VERSION}"
python3 -m pip install --user "https://github.com/konflux-ci/rpm-lockfile-prototype/archive/${RPM_LOCKFILE_PROTOTYPE_VERSION}.zip" &>/dev/null

echo "STEP 7: Repository configuration for rpm-lockfile-prototype..."
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

if [ "${USE_RHSM_RHEL9}" = "true" ]; then
    echo "RHSM mode: Using subscription-based repositories for certificate access."
else
    echo "UBI mode: Using public UBI repositories."
    echo "Available container repositories:"
    dnf repolist --enabled || true
fi

# Copy the final repository configuration for output
cp /etc/yum.repos.d/redhat.repo /source/redhat.repo 2>/dev/null || echo "# No redhat.repo found" > /source/redhat.repo

echo "STEP 8: Generating lock file for image: ${RHEL8_IMAGE_TO_LOCK}"
/root/.local/bin/rpm-lockfile-prototype \
    --image "${RHEL8_IMAGE_TO_LOCK}" \
    --outfile="/source/rpms.lock.yaml" \
    /source/rpms.out.yaml

echo "Lock file generation complete inside the container."
EOF

# Ensure the temporary script is executable
chmod +x "${SCRIPT_FILE_PATH}"

echo "Running container to perform certificate swap and generate lock files..."
echo "Using execution image: ${RHEL9_EXECUTION_IMAGE}"
podman run --rm -it ${AUTH_MOUNT_FLAG} ${PODMAN_FLAGS} -v "${ABS_PROJECT_DIR}:/source:Z" --entrypoint /source/podman_script.sh "${RHEL9_EXECUTION_IMAGE}"

echo -e "\n--- Success! ---"
echo "Generated files for RHEL 8 are located in '${ABS_PROJECT_DIR}'."
echo "Please review and commit the following files:"
echo "  - redhat.repo"
echo "  - rpms.out.yaml (modified input file with runtime changes)"
echo "  - rpms.lock.yaml"

# Clean up temporary files
if [ -f "${ABS_PROJECT_DIR}/${RHEL8_REPO_FILE}" ]; then
    echo "Cleaning up temporary file: ${RHEL8_REPO_FILE}"
    rm -f "${ABS_PROJECT_DIR}/${RHEL8_REPO_FILE}"
fi

echo "--------------------"
