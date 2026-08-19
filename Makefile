# PlayOS Reference Distribution — Developer Makefile
#
# Usage:
#   make setup            Clone Buildroot, check dependencies
#   make qemu-config      Open menuconfig for QEMU target
#   make qemu-build       Full image build for QEMU
#   make qemu-run         Boot image in QEMU/OVMF
#   make ally-config      Open menuconfig for ROG Ally target
#   make ally-build       Full image build for ROG Ally
#   make ally-usb-image   Produce USB-bootable disk image
#   make ally-flash       Flash image to USB drive (prompts for device)
#   make installer-config Open menuconfig for the installer target
#   make installer-build  Full image build for the installer
#   make installer-image  Produce one-shot installer USB image (needs ally-build)
#   make installer-flash  Flash installer image to USB (prompts for device)
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
INSTALLER_DEFCONFIG := $(BR2_EXTERNAL)/configs/playos_ally_installer_defconfig
INSTALLER_OUTPUT := $(CURDIR)/output/installer
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

.PHONY: ally-usb-image
ally-usb-image: ally-build ## Produce a USB-bootable disk image for the ROG Ally
	@echo "==> Creating USB-bootable image for ROG Ally..."
	@bash "$(SCRIPTS_DIR)/gen-ally-usb-image.sh" "$(ALLY_OUTPUT)"

.PHONY: ally-flash
ally-flash: ally-usb-image ## Flash PlayOS to a USB drive (prompts for device)
	@echo "==> USB image: $(ALLY_OUTPUT)/images/playos-ally-usb.img"
	@echo "==> Run: sudo bash scripts/flash-usb.sh $(ALLY_OUTPUT)/images/playos-ally-usb.img"

# ── Installer targets ─────────────────────────────────────────────────────
.PHONY: installer-config
installer-config: ## Open menuconfig for the installer target
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(INSTALLER_OUTPUT)" \
		$(notdir $(INSTALLER_DEFCONFIG))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(INSTALLER_OUTPUT)" \
		menuconfig

.PHONY: installer-build
installer-build: ## Full image build for the installer (requires setup)
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(INSTALLER_OUTPUT)" \
		$(notdir $(INSTALLER_DEFCONFIG))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(INSTALLER_OUTPUT)" \
		$(addsuffix -dirclean,$(PLAYOS_LOCAL_PACKAGES))
	@$(MAKE) -C "$(BUILDROOT_DIR)" \
		BR2_EXTERNAL="$(BR2_EXTERNAL)" \
		O="$(INSTALLER_OUTPUT)"

.PHONY: installer-image
installer-image: installer-build ally-build ## Produce one-shot installer USB image
	@echo "==> Creating installer USB image..."
	@bash "$(SCRIPTS_DIR)/gen-installer-usb-image.sh" "$(INSTALLER_OUTPUT)" "$(ALLY_OUTPUT)"

.PHONY: installer-flash
installer-flash: installer-image ## Flash installer image to USB (prompts for device)
	@echo "==> Installer image: $(INSTALLER_OUTPUT)/images/playos-ally-installer.img"
	@echo "==> Run: sudo bash scripts/flash-usb.sh $(INSTALLER_OUTPUT)/images/playos-ally-installer.img"

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
	@rm -rf "$(QEMU_OUTPUT)" "$(ALLY_OUTPUT)" "$(INSTALLER_OUTPUT)"
	@echo "Build output cleaned. dl/ cache preserved."

.PHONY: distclean
distclean: ## Remove everything including dl/ and buildroot/
	@rm -rf "$(QEMU_OUTPUT)" "$(ALLY_OUTPUT)" "$(INSTALLER_OUTPUT)" "$(BUILDROOT_DIR)"
	@echo "Full distclean complete."
