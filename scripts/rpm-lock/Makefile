# RPM Lock Scripts Makefile
# ==========================
# This Makefile provides targets for generating RPM lock files and filtering repositories.

# Get the directory of the current makefile
# Trim any trailing slash from the directory path as we will add if when necessary later
PROJECT_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# Path for the filter-unused-repos target
REPO_FILE ?= redhat.repo

# Target directory for the lock scripts
# This should be configured by the caller of the Makefile
LOCK_SCRIPT_TARGET_DIR ?= $(PROJECT_DIR)

# The following variables are used for registering the system with Red Hat
# These should be configured by the caller of the Makefile
RHEL9_ACTIVATION_KEY ?= 1234567890
RHEL9_ORG_ID ?= placeholder
RHEL8_ACTIVATION_KEY ?= 1234567890
RHEL8_ORG_ID ?= placeholder

# Container images - can be overridden from the command line
RHEL9_IMAGE ?= registry.redhat.io/rhel9-4-els/rhel
RHEL9_MINIMAL_IMAGE ?= registry.redhat.io/rhel9-4-els/rhel-minimal
RHEL9_RELEASE ?= 9.4

UBI8_IMAGE ?= registry.redhat.io/ubi8/ubi
UBI8_MINIMAL_IMAGE ?= registry.redhat.io/ubi8/ubi-minimal
UBI8_RELEASE ?= 8.10

UBI9_IMAGE ?= registry.redhat.io/ubi9/ubi
UBI9_RELEASE ?= 9.4

RHEL9_EXECUTION_IMAGE ?= $(RHEL9_IMAGE):$(RHEL9_RELEASE)
UBI8_EXECUTION_IMAGE ?= $(UBI8_IMAGE):$(UBI8_RELEASE)
UBI9_EXECUTION_IMAGE ?= $(UBI9_IMAGE):$(UBI9_RELEASE)

RHEL9_IMAGE_TO_LOCK ?= $(RHEL9_MINIMAL_IMAGE):$(RHEL9_RELEASE)
UBI8_IMAGE_TO_LOCK ?= $(UBI8_MINIMAL_IMAGE):$(UBI8_RELEASE)

# The registry auth file is mounted into the container to allow for private registry pulls.
# This is automatically detected and mounted into the container if it exists on the host.
# If it does not exist, a warning is printed and the registry pulls may fail if not public.
# This can be set from the command line if the default is not correct for your environment.
REGISTRY_AUTH_FILE ?= $(shell echo $${XDG_RUNTIME_DIR:-/run/user/$$(shell id -u)})/containers/auth.json

# === Targets ===
.PHONY: all
all: help ## Run the default target (prints help).

.PHONY: filter-unused-repos
filter-unused-repos: ## Filter unused repositories from redhat.repo files (use REPO_FILE=path)
	@echo "Filtering unused repositories from $(REPO_FILE)..."
	$(PROJECT_DIR)/konflux-filter-unused-repos.sh $(REPO_FILE) > $(REPO_FILE).tmp && mv $(REPO_FILE).tmp $(REPO_FILE)

.PHONY: generate-rhel9-locks
generate-rhel9-locks: ## Generate RHEL 9 lock files. Override images with RHEL9_IMAGE, RHEL9_MINIMAL_IMAGE.
	@echo "Running RHEL 9 lock file generation script..."
	@export \
		RHEL9_EXECUTION_IMAGE=$(RHEL9_EXECUTION_IMAGE) \
		IMAGE_TO_LOCK=$(RHEL9_IMAGE_TO_LOCK) \
		RHEL9_RELEASE=$(RHEL9_RELEASE) \
		RHEL9_ACTIVATION_KEY=$(RHEL9_ACTIVATION_KEY) \
		RHEL9_ORG_ID=$(RHEL9_ORG_ID) \
		REGISTRY_AUTH_FILE=$(REGISTRY_AUTH_FILE); \
	$(PROJECT_DIR)/generate-rhel9-locks.sh $(LOCK_SCRIPT_TARGET_DIR)

.PHONY: generate-ubi8-locks
generate-ubi8-locks: ## Generate UBI 8 lock files. Override images with UBI8_IMAGE, UBI9_IMAGE, etc.
	@echo "Running UBI 8 lock file generation script (workaround)..."
	@export \
		UBI8_EXECUTION_IMAGE=$(UBI8_EXECUTION_IMAGE) \
		UBI9_EXECUTION_IMAGE=$(UBI9_EXECUTION_IMAGE) \
		IMAGE_TO_LOCK=$(UBI8_IMAGE_TO_LOCK) \
		UBI8_RELEASE=$(UBI8_RELEASE) \
		UBI9_RELEASE=$(UBI9_RELEASE) \
		RHEL8_ACTIVATION_KEY=$(RHEL8_ACTIVATION_KEY) \
		RHEL8_ORG_ID=$(RHEL8_ORG_ID) \
		RHEL9_ACTIVATION_KEY=$(RHEL9_ACTIVATION_KEY) \
		RHEL9_ORG_ID=$(RHEL9_ORG_ID) \
		REGISTRY_AUTH_FILE=$(REGISTRY_AUTH_FILE); \
	$(PROJECT_DIR)/generate-ubi8-locks.sh $(LOCK_SCRIPT_TARGET_DIR)

.PHONY: help
help: ## Display available targets and variables.
	@echo "RPM Lock Scripts"
	@echo "==============="
	@echo ""
	@echo "This Makefile provides targets for generating RPM lock files and filtering repositories."
	@echo ""
	@echo "Variables:"
	@echo "  LOCK_SCRIPT_TARGET_DIR The project directory to run the scripts against (default: .)"
	@echo "  REPO_FILE           Path to redhat.repo file for filtering (default: redhat.repo)"
	@echo "  RHEL9_IMAGE         Image for RHEL9 generation (default: registry.redhat.io/rhel9-4-els/rhel)"
	@echo "  RHEL9_MINIMAL_IMAGE Image for RHEL9 minimal runtime (default: .../rhel-minimal)"
	@echo "  RHEL9_RELEASE       Release for RHEL9 generation (default: 9.4)"
	@echo "  UBI8_IMAGE          Image for UBI8 generation (default: registry.redhat.io/ubi8/ubi)"
	@echo "  UBI8_MINIMAL_IMAGE  Minimal image for UBI8 runtime (default: .../ubi-minimal)"
	@echo "  UBI8_RELEASE       Release for UBI8 generation (default: 8.10)"
	@echo "  UBI9_IMAGE          Helper image for UBI8 workaround (default: registry.redhat.io/ubi9/ubi)"
	@echo "  UBI9_RELEASE       Release for UBI9 generation (default: 9.4)"
	@echo "  RHEL9_ACTIVATION_KEY Red Hat Activation Key for RHEL9 (default: 1234567890)"
	@echo "  RHEL9_ORG_ID       Red Hat Organization ID for RHEL9 (default: placeholder)"
	@echo "  RHEL8_ACTIVATION_KEY Red Hat Activation Key for RHEL8 (default: 1234567890)"
	@echo "  RHEL8_ORG_ID       Red Hat Organization ID for RHEL8 (default: placeholder)"
	@echo ""
	@echo "Examples:"
	@echo "  make generate-rhel9-locks LOCK_SCRIPT_TARGET_DIR=/path/to/project \\"
	@echo "       RHEL9_ACTIVATION_KEY=1234567890 RHEL9_ORG_ID=placeholder"
	@echo ""
	@echo "  make generate-rhel9-locks RHEL9_IMAGE=my-registry/rhel9-4-els/rhel \\"
	@echo "       RHEL9_MINIMAL_IMAGE=my-registry/rhel9-4-els/rhel-minimal \\"
	@echo "       RHEL9_RELEASE=9.4 RHEL9_ACTIVATION_KEY=1234567890 RHEL9_ORG_ID=placeholder"
	@echo ""
	@echo "  make generate-ubi8-locks LOCK_SCRIPT_TARGET_DIR=/path/to/project \\"
	@echo "       RHEL8_ACTIVATION_KEY=1234567890 RHEL8_ORG_ID=placeholder \\"
	@echo "       RHEL9_ACTIVATION_KEY=1234567890 RHEL9_ORG_ID=placeholder"
	@echo ""
	@echo "  make generate-ubi8-locks UBI8_IMAGE=my-registry/ubi \\"
	@echo "       UBI8_MINIMAL_IMAGE=my-registry/ubi-minimal UBI8_RELEASE=8.10 \\"
	@echo "       UBI9_IMAGE=my-registry/ubi UBI9_RELEASE=9.4 \\"
	@echo "       RHEL8_ACTIVATION_KEY=1234567890 RHEL8_ORG_ID=placeholder \\"
	@echo "       RHEL9_ACTIVATION_KEY=1234567890 RHEL9_ORG_ID=placeholder"
	@echo ""
	@echo "  make filter-unused-repos REPO_FILE=/path/to/file"
	@echo ""
	@echo "Available targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-22s %s\n", $$1, $$2}' $(PROJECT_DIR)/Makefile
