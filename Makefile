# PlayOS Reference Distribution — Developer Makefile
#
# Usage:
#   make setup            Clone Buildroot, check dependencies
#   make qemu-config      Open menuconfig for QEMU target
#   make qemu-build       Full image build for QEMU
#   make qemu-run         Boot image in QEMU/OVMF
#   make ally-config      Open menuconfig for ROG Ally target
#   make ally-build       Full image build for ROG Ally (dev image)
#   make ally-production-build  Full image build for ROG Ally (production image)
#   make ally-usb-image   Produce USB-bootable disk image
#   make ally-flash       Flash image to USB drive (prompts for device)
#   make intel-config     Open menuconfig for Intel PC target
#   make intel-build      Full image build for Intel PC (dev image)
#   make intel-usb-image  Produce USB-bootable disk image for Intel PC
#   make intel-flash      Flash Intel image to USB drive (prompts for device)
#   make ally-dev-usb-image / ally-prod-usb-image   Consolidated dev/prod live+installer images
#   make ally-dev-flash / ally-prod-flash           Flash them
#   make intel-dev-usb-image / intel-dev-flash      Intel dev flavor
#   make update-bundle    Build a dev-signed update bundle (.playosb)
#   make clean            Remove build output (preserves dl/ cache)
#   make distclean        Remove everything including dl/
#
# This Makefile wraps Buildroot's build system with PlayOS conventions.

# ── Paths ────────────────────────────────────────────────────────────────
BR2_EXTERNAL := $(CURDIR)/br2-external
BUILDROOT_DIR := $(CURDIR)/buildroot
QEMU_DEFCONFIG := $(BR2_EXTERNAL)/configs/playos_qemu_x86_64_defconfig
QEMU_OUTPUT := $(CURDIR)/output/qemu
ALLY_DEFCONFIG := $(BR2_EXTERNAL)/configs/playos_ally_defconfig
ALLY_OUTPUT := $(CURDIR)/output/ally
ALLY_PRODUCTION_DEFCONFIG := $(BR2_EXTERNAL)/configs/playos_ally_production_defconfig
ALLY_PRODUCTION_OUTPUT := $(CURDIR)/output/ally-production
INTEL_DEFCONFIG := $(BR2_EXTERNAL)/configs/playos_intel_pc_defconfig
INTEL_OUTPUT := $(CURDIR)/output/intel
SCRIPTS_DIR := $(CURDIR)/scripts
# Local-site packages are rsync'd into the Buildroot output only on the first
# build; Buildroot does NOT re-sync them when sources under src/ change. We
# dirclean them before every build so edits to src/<component> are always
# picked up (see playos-*.mk SITE_METHOD = local).
PLAYOS_LOCAL_PACKAGES := playos-init playos-runtime playos-compositor playos-shell \
	playos-platform-api playos-raylib playos-overlay playos-installer playos-samples

# Source shared logging (if present)
-include $(SCRIPTS_DIR)/lib/playos_log.mk

# ── Version pins (from versions.lock) ────────────────────────────────────
VERSIONS_LOCK := $(CURDIR)/versions.lock
BUILDROOT_COMMIT := $(shell grep -s '^BUILDROOT_COMMIT=' $(VERSIONS_LOCK) 2>/dev/null | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | xargs)
PLAYOS_INIT_COMMIT := $(shell grep -s '^PLAYOS_INIT_COMMIT=' $(VERSIONS_LOCK) 2>/dev/null | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | xargs)
PLAYOS_COMPOSITOR_COMMIT := $(shell grep -s '^PLAYOS_COMPOSITOR_COMMIT=' $(VERSIONS_LOCK) 2>/dev/null | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | xargs)
PLAYOS_RUNTIME_COMMIT := $(shell grep -s '^PLAYOS_RUNTIME_COMMIT=' $(VERSIONS_LOCK) 2>/dev/null | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | xargs)
PLAYOS_PLATFORM_API_COMMIT := $(shell grep -s '^PLAYOS_PLATFORM_API_COMMIT=' $(VERSIONS_LOCK) 2>/dev/null | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | xargs)
PLAYOS_SHELL_COMMIT := $(shell grep -s '^PLAYOS_SHELL_COMMIT=' $(VERSIONS_LOCK) 2>/dev/null | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | xargs)
PLAYOS_SAMPLES_COMMIT := $(shell grep -s '^PLAYOS_SAMPLES_COMMIT=' $(VERSIONS_LOCK) 2>/dev/null | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | xargs)

# ── Default target ───────────────────────────────────────────────────────
.DEFAULT_GOAL := help

help: ## Show this help
	@echo "PlayOS Reference Distribution"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Setup ────────────────────────────────────────────────────────────────
.PHONY: verify-pins
verify-pins: ## Verify versions.lock pins are all set
	@bash "$(SCRIPTS_DIR)/verify-versions.sh" "$(VERSIONS_LOCK)"

.PHONY: setup
setup: verify-pins ## Clone Buildroot, apply br2-external, check dependencies
	@echo "==> Setting up PlayOS build environment..."
	@git config --global advice.detachedHead false
	@if [ ! -d "$(BUILDROOT_DIR)" ]; then \
		echo "==> Cloning Buildroot (shallow, 100 commits)..."; \
		git clone --depth 100 https://git.buildroot.net/buildroot "$(BUILDROOT_DIR)"; \
	fi
	@if [ -n "$(BUILDROOT_COMMIT)" ]; then \
		if ! git -C "$(BUILDROOT_DIR)" cat-file -e "$(BUILDROOT_COMMIT)^{commit}" 2>/dev/null; then \
			echo "==> Fetching Buildroot history to reach $(BUILDROOT_COMMIT)..."; \
			if git -C "$(BUILDROOT_DIR)" rev-parse --is-shallow-repository | grep -q true; then \
				git -C "$(BUILDROOT_DIR)" fetch --unshallow origin; \
			else \
				git -C "$(BUILDROOT_DIR)" fetch origin; \
			fi; \
		fi; \
		echo "==> Pinning Buildroot to $(BUILDROOT_COMMIT)..."; \
		git -C "$(BUILDROOT_DIR)" checkout --detach "$(BUILDROOT_COMMIT)"; \
	fi
	@echo "==> Cloning source repositories..."
	@if [ ! -d "$(CURDIR)/src/playos-init" ]; then \
		echo "  -> playos-init..."; \
		git clone https://github.com/PlayOS-Foundation/playos-init.git "$(CURDIR)/src/playos-init"; \
	fi
	@if [ -n "$(PLAYOS_INIT_COMMIT)" ] && [ -d "$(CURDIR)/src/playos-init/.git" ] && [ ! -L "$(CURDIR)/src/playos-init" ]; then \
		echo "  -> playos-init: checkout $(PLAYOS_INIT_COMMIT)..."; \
		git -C "$(CURDIR)/src/playos-init" fetch origin && \
		git -C "$(CURDIR)/src/playos-init" checkout "$(PLAYOS_INIT_COMMIT)"; \
	fi
	@if [ ! -d "$(CURDIR)/src/playos-compositor" ]; then \
		echo "  -> playos-compositor..."; \
		git clone https://github.com/PlayOS-Foundation/playos-compositor.git "$(CURDIR)/src/playos-compositor"; \
	fi
	@if [ -n "$(PLAYOS_COMPOSITOR_COMMIT)" ] && [ -d "$(CURDIR)/src/playos-compositor/.git" ] && [ ! -L "$(CURDIR)/src/playos-compositor" ]; then \
		echo "  -> playos-compositor: checkout $(PLAYOS_COMPOSITOR_COMMIT)..."; \
		git -C "$(CURDIR)/src/playos-compositor" fetch origin && \
		git -C "$(CURDIR)/src/playos-compositor" checkout "$(PLAYOS_COMPOSITOR_COMMIT)"; \
	fi
	@if [ ! -d "$(CURDIR)/src/playos-runtime" ]; then \
		echo "  -> playos-runtime..."; \
		git clone https://github.com/PlayOS-Foundation/playos-runtime.git "$(CURDIR)/src/playos-runtime"; \
	fi
	@if [ -n "$(PLAYOS_RUNTIME_COMMIT)" ] && [ -d "$(CURDIR)/src/playos-runtime/.git" ] && [ ! -L "$(CURDIR)/src/playos-runtime" ]; then \
		echo "  -> playos-runtime: checkout $(PLAYOS_RUNTIME_COMMIT)..."; \
		git -C "$(CURDIR)/src/playos-runtime" fetch origin && \
		git -C "$(CURDIR)/src/playos-runtime" checkout "$(PLAYOS_RUNTIME_COMMIT)"; \
	fi
	@if [ ! -d "$(CURDIR)/src/playos-platform-api" ]; then \
		echo "  -> playos-platform-api..."; \
		git clone https://github.com/PlayOS-Foundation/playos-platform-api.git "$(CURDIR)/src/playos-platform-api"; \
	fi
	@if [ -n "$(PLAYOS_PLATFORM_API_COMMIT)" ] && [ -d "$(CURDIR)/src/playos-platform-api/.git" ] && [ ! -L "$(CURDIR)/src/playos-platform-api" ]; then \
		echo "  -> playos-platform-api: checkout $(PLAYOS_PLATFORM_API_COMMIT)..."; \
		git -C "$(CURDIR)/src/playos-platform-api" fetch origin && \
		git -C "$(CURDIR)/src/playos-platform-api" checkout "$(PLAYOS_PLATFORM_API_COMMIT)"; \
	fi
	@if [ ! -d "$(CURDIR)/src/playos-shell" ]; then \
		echo "  -> playos-shell..."; \
		git clone https://github.com/PlayOS-Foundation/playos-shell.git "$(CURDIR)/src/playos-shell"; \
	fi
	@if [ -n "$(PLAYOS_SHELL_COMMIT)" ] && [ -d "$(CURDIR)/src/playos-shell/.git" ] && [ ! -L "$(CURDIR)/src/playos-shell" ]; then \
		echo "  -> playos-shell: checkout $(PLAYOS_SHELL_COMMIT)..."; \
		git -C "$(CURDIR)/src/playos-shell" fetch origin && \
		git -C "$(CURDIR)/src/playos-shell" checkout "$(PLAYOS_SHELL_COMMIT)"; \
	fi
	@if [ ! -d "$(CURDIR)/src/playos-samples" ]; then \
		echo "  -> playos-samples..."; \
		git clone https://github.com/PlayOS-Foundation/playos-samples.git "$(CURDIR)/src/playos-samples"; \
	fi
	@if [ -n "$(PLAYOS_SAMPLES_COMMIT)" ] && [ -d "$(CURDIR)/src/playos-samples/.git" ] && [ ! -L "$(CURDIR)/src/playos-samples" ]; then \
		echo "  -> playos-samples: checkout $(PLAYOS_SAMPLES_COMMIT)..."; \
		git -C "$(CURDIR)/src/playos-samples" fetch origin && \
		git -C "$(CURDIR)/src/playos-samples" checkout "$(PLAYOS_SAMPLES_COMMIT)"; \
	fi
	@echo "==> Applying br2-external..."
	@$(MAKE) -C "$(BUILDROOT_DIR)" BR2_EXTERNAL="$(BR2_EXTERNAL)" help > /dev/null 2>&1 || \
		(echo "ERROR: Buildroot setup failed. Run 'make distclean' and retry." && exit 1)
	@echo "==> Setup complete."
	@echo "    Next: make qemu-build"

# ── QEMU targets ─────────────────────────────────────────────────────────
.PHONY: qemu-config
qemu-config: ## Open menuconfig for QEMU target
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(QEMU_OUTPUT)" \
		$(notdir $(QEMU_DEFCONFIG))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(QEMU_OUTPUT)" \
		menuconfig

.PHONY: qemu-build
qemu-build: ## Full image build for QEMU (requires setup)
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(QEMU_OUTPUT)" \
		$(notdir $(QEMU_DEFCONFIG))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(QEMU_OUTPUT)" \
		$(addsuffix -dirclean,$(PLAYOS_LOCAL_PACKAGES))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(QEMU_OUTPUT)"

.PHONY: qemu-run
qemu-run: ## Boot the QEMU image in QEMU/OVMF
	@echo "==> Booting PlayOS in QEMU/OVMF..."
	@bash "$(SCRIPTS_DIR)/qemu-boot-check.sh"

.PHONY: qemu-pivot-check
qemu-pivot-check: ## Verify A/B slot pivot + forced rollback in QEMU
	@echo "==> Running A/B pivot + rollback check in QEMU..."
	@bash "$(SCRIPTS_DIR)/qemu-pivot-check.sh"

# ── ROG Ally targets ─────────────────────────────────────────────────────
.PHONY: ally-config
ally-config: ## Open menuconfig for ROG Ally target
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(ALLY_OUTPUT)" \
		$(notdir $(ALLY_DEFCONFIG))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(ALLY_OUTPUT)" \
		menuconfig

.PHONY: ally-build
ally-build: ## Full image build for ROG Ally (requires setup)
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(ALLY_OUTPUT)" \
		$(notdir $(ALLY_DEFCONFIG))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(ALLY_OUTPUT)" \
		$(addsuffix -dirclean,$(PLAYOS_LOCAL_PACKAGES))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(ALLY_OUTPUT)"

.PHONY: ally-production-build
ally-production-build: ## Full production image build for ROG Ally (Sprint 12)
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(ALLY_PRODUCTION_OUTPUT)" \
		$(notdir $(ALLY_PRODUCTION_DEFCONFIG))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(ALLY_PRODUCTION_OUTPUT)" \
		$(addsuffix -dirclean,$(PLAYOS_LOCAL_PACKAGES))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(ALLY_PRODUCTION_OUTPUT)"

.PHONY: ally-usb-image
ally-usb-image: ally-build ## Produce a USB-bootable disk image for the ROG Ally
	@echo "==> Creating USB-bootable image for ROG Ally..."
	@bash "$(SCRIPTS_DIR)/gen-ally-usb-image.sh" "$(ALLY_OUTPUT)"

.PHONY: ally-flash
ally-flash: ally-usb-image ## Flash PlayOS to a USB drive (prompts for device)
	@echo "==> USB image: $(ALLY_OUTPUT)/images/playos-ally-usb.img"
	@echo "==> Run: sudo bash scripts/flash-usb.sh $(ALLY_OUTPUT)/images/playos-ally-usb.img"

# ── Intel PC targets (Sprint 13) ────────────────────────────────────────
.PHONY: intel-config
intel-config: ## Open menuconfig for Intel PC target
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(INTEL_OUTPUT)" \
		$(notdir $(INTEL_DEFCONFIG))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(INTEL_OUTPUT)" \
		menuconfig

.PHONY: intel-build
intel-build: ## Full image build for Intel PC (requires setup)
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(INTEL_OUTPUT)" \
		$(notdir $(INTEL_DEFCONFIG))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(INTEL_OUTPUT)" \
		$(addsuffix -dirclean,$(PLAYOS_LOCAL_PACKAGES))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(INTEL_OUTPUT)"

.PHONY: intel-usb-image
intel-usb-image: intel-build ## Produce a USB-bootable disk image for the Intel PC
	@echo "==> Creating USB-bootable image for Intel PC..."
	@bash "$(SCRIPTS_DIR)/gen-intel-usb-image.sh" "$(INTEL_OUTPUT)"

.PHONY: intel-flash
intel-flash: intel-usb-image ## Flash Intel image to USB drive (prompts for device)
	@echo "==> USB image: $(INTEL_OUTPUT)/images/playos-intel-usb.img"
	@echo "==> Run: sudo bash scripts/flash-usb.sh $(INTEL_OUTPUT)/images/playos-intel-usb.img"

# ── Consolidated dev/prod live+installer USB images (Sprint 13.7) ────────
# Each image boots live to the shell AND carries the install payload on
# playos-a, so "Install PlayOS to internal disk" works from Settings.
# Dev images seed the SSH key; prod images do not (no Dropbear in prod).
.PHONY: ally-dev-usb-image
ally-dev-usb-image: ally-build ## Produce dev ROG Ally USB image (SSH + install payload)
	@bash "$(SCRIPTS_DIR)/gen-ally-usb-image.sh" "$(ALLY_OUTPUT)" playos-ally-dev-usb.img dev

.PHONY: ally-prod-usb-image
ally-prod-usb-image: ally-production-build ## Produce prod ROG Ally USB image (no SSH + install payload)
	@bash "$(SCRIPTS_DIR)/gen-ally-usb-image.sh" "$(ALLY_PRODUCTION_OUTPUT)" playos-ally-prod-usb.img prod

.PHONY: ally-dev-flash
ally-dev-flash: ally-dev-usb-image ## Flash dev ROG Ally USB image (prompts for device)
	@echo "==> Dev USB image: $(ALLY_OUTPUT)/images/playos-ally-dev-usb.img"
	@echo "==> Run: sudo bash scripts/flash-usb.sh $(ALLY_OUTPUT)/images/playos-ally-dev-usb.img"

.PHONY: ally-prod-flash
ally-prod-flash: ally-prod-usb-image ## Flash prod ROG Ally USB image (prompts for device)
	@echo "==> Prod USB image: $(ALLY_PRODUCTION_OUTPUT)/images/playos-ally-prod-usb.img"
	@echo "==> Run: sudo bash scripts/flash-usb.sh $(ALLY_PRODUCTION_OUTPUT)/images/playos-ally-prod-usb.img"

.PHONY: intel-dev-usb-image
intel-dev-usb-image: intel-build ## Produce dev Intel USB image (SSH + install payload)
	@bash "$(SCRIPTS_DIR)/gen-intel-usb-image.sh" "$(INTEL_OUTPUT)" playos-intel-dev-usb.img dev

.PHONY: intel-dev-flash
intel-dev-flash: intel-dev-usb-image ## Flash dev Intel USB image (prompts for device)
	@echo "==> Dev USB image: $(INTEL_OUTPUT)/images/playos-intel-dev-usb.img"
	@echo "==> Run: sudo bash scripts/flash-usb.sh $(INTEL_OUTPUT)/images/playos-intel-dev-usb.img"

# ── Update bundle ─────────────────────────────────────────────────────────
VERSION ?= 0.2.0

.PHONY: update-bundle
update-bundle: ## Build a dev-signed update bundle from the ally rootfs.squashfs
	@echo "==> Building update bundle (version $(VERSION))..."
	@bash "$(SCRIPTS_DIR)/create-update-bundle.sh" \
		"$(ALLY_OUTPUT)/images/rootfs.squashfs" \
		"$(VERSION)" \
		"$(CURDIR)/output/images/playos-$(VERSION).playosb"

# ── Clean targets ────────────────────────────────────────────────────────
.PHONY: clean
clean: ## Remove build output (preserves dl/ cache)
	@rm -rf "$(QEMU_OUTPUT)" "$(ALLY_OUTPUT)" "$(ALLY_PRODUCTION_OUTPUT)" "$(INTEL_OUTPUT)"
	@echo "Build output cleaned. dl/ cache preserved."

.PHONY: distclean
distclean: ## Remove everything including dl/ and buildroot/
	@rm -rf "$(QEMU_OUTPUT)" "$(ALLY_OUTPUT)" "$(ALLY_PRODUCTION_OUTPUT)" "$(INTEL_OUTPUT)" "$(BUILDROOT_DIR)"
	@echo "Full distclean complete."
