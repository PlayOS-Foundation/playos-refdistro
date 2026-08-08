# PlayOS Reference Distribution — Developer Makefile
#
# Usage:
#   make setup          Clone Buildroot, check dependencies
#   make qemu-config    Open menuconfig for QEMU target
#   make qemu-build     Full image build for QEMU
#   make qemu-run       Boot image in QEMU/OVMF
#   make ally-config    Open menuconfig for ROG Ally target
#   make ally-build     Full image build for ROG Ally
#   make ally-usb-image Produce USB-bootable disk image
#   make ally-flash     Flash image to USB drive (prompts for device)
#   make clean          Remove build output (preserves dl/ cache)
#   make distclean      Remove everything including dl/
#
# This Makefile wraps Buildroot's build system with PlayOS conventions.

# ── Paths ────────────────────────────────────────────────────────────────
BR2_EXTERNAL := $(CURDIR)/br2-external
BUILDROOT_DIR := $(CURDIR)/buildroot
QEMU_DEFCONFIG := $(BR2_EXTERNAL)/configs/playos_qemu_x86_64_defconfig
QEMU_OUTPUT := $(CURDIR)/output/qemu
ALLY_DEFCONFIG := $(BR2_EXTERNAL)/configs/playos_ally_defconfig
ALLY_OUTPUT := $(CURDIR)/output/ally
SCRIPTS_DIR := $(CURDIR)/scripts

# Source shared logging (if present)
-include $(SCRIPTS_DIR)/lib/playos_log.mk

# ── Version pins (from versions.lock) ────────────────────────────────────
VERSIONS_LOCK := $(CURDIR)/versions.lock
PLAYOS_INIT_COMMIT := $(shell grep -s '^PLAYOS_INIT_COMMIT=' $(VERSIONS_LOCK) 2>/dev/null | cut -d= -f2- | xargs)
PLAYOS_COMPOSITOR_COMMIT := $(shell grep -s '^PLAYOS_COMPOSITOR_COMMIT=' $(VERSIONS_LOCK) 2>/dev/null | cut -d= -f2- | xargs)
PLAYOS_RUNTIME_COMMIT := $(shell grep -s '^PLAYOS_RUNTIME_COMMIT=' $(VERSIONS_LOCK) 2>/dev/null | cut -d= -f2- | xargs)

# ── Default target ───────────────────────────────────────────────────────
.DEFAULT_GOAL := help

help: ## Show this help
	@echo "PlayOS Reference Distribution"
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z_-]+:.*##' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# ── Setup ────────────────────────────────────────────────────────────────
.PHONY: setup
setup: ## Clone Buildroot, apply br2-external, check dependencies
	@echo "==> Setting up PlayOS build environment..."
	@if [ ! -d "$(BUILDROOT_DIR)" ]; then \
		echo "==> Cloning Buildroot..."; \
		git clone --depth 1 https://git.buildroot.net/buildroot "$(BUILDROOT_DIR)"; \
	fi
	@echo "==> Cloning source repositories..."
	@if [ ! -d "$(CURDIR)/src/playos-init" ]; then \
		echo "  -> playos-init..."; \
		git clone https://github.com/PlayOS-Foundation/playos-init.git "$(CURDIR)/src/playos-init"; \
		if [ -n "$(PLAYOS_INIT_COMMIT)" ]; then \
			cd "$(CURDIR)/src/playos-init" && \
			git fetch origin && git checkout "$(PLAYOS_INIT_COMMIT)"; \
		fi; \
	fi
	@if [ ! -d "$(CURDIR)/src/playos-compositor" ]; then \
		echo "  -> playos-compositor..."; \
		git clone https://github.com/PlayOS-Foundation/playos-compositor.git "$(CURDIR)/src/playos-compositor"; \
		if [ -n "$(PLAYOS_COMPOSITOR_COMMIT)" ]; then \
			cd "$(CURDIR)/src/playos-compositor" && \
			git fetch origin && git checkout "$(PLAYOS_COMPOSITOR_COMMIT)"; \
		fi; \
	fi
	@if [ ! -d "$(CURDIR)/src/playos-runtime" ]; then \
		echo "  -> playos-runtime..."; \
		git clone https://github.com/PlayOS-Foundation/playos-runtime.git "$(CURDIR)/src/playos-runtime"; \
		if [ -n "$(PLAYOS_RUNTIME_COMMIT)" ]; then \
			cd "$(CURDIR)/src/playos-runtime" && \
			git fetch origin && git checkout "$(PLAYOS_RUNTIME_COMMIT)"; \
		fi; \
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
		O="$(QEMU_OUTPUT)"

.PHONY: qemu-run
qemu-run: ## Boot the QEMU image in QEMU/OVMF
	@echo "==> Booting PlayOS in QEMU/OVMF..."
	@bash "$(SCRIPTS_DIR)/qemu-boot-check.sh"

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
		O="$(ALLY_OUTPUT)"

.PHONY: ally-usb-image
ally-usb-image: ally-build ## Produce a USB-bootable disk image for the ROG Ally
	@echo "==> Creating USB-bootable image for ROG Ally..."
	@bash "$(SCRIPTS_DIR)/gen-ally-usb-image.sh" "$(ALLY_OUTPUT)"

.PHONY: ally-flash
ally-flash: ally-usb-image ## Flash PlayOS to a USB drive (prompts for device)
	@echo "==> Available block devices:"
	@lsblk -d -o NAME,SIZE,MODEL,TYPE | grep -E 'disk|NAME'
	@echo ""
	@read -p "Enter target USB device (e.g. sdb): " USB_DEV; \
	if [ -z "$$USB_DEV" ]; then \
		echo "ERROR: No device specified."; exit 1; \
	fi; \
	USB_PATH="/dev/$$USB_DEV"; \
	if [ ! -b "$$USB_PATH" ]; then \
		echo "ERROR: $$USB_PATH is not a block device."; exit 1; \
	fi; \
	echo ""; \
	echo "WARNING: This will ERASE ALL DATA on $$USB_PATH!"; \
	read -p "Are you sure? Type YES to confirm: " CONFIRM; \
	if [ "$$CONFIRM" != "YES" ]; then \
		echo "Aborted."; exit 1; \
	fi; \
	echo "==> Writing image to $$USB_PATH..."; \
	IMAGE="$(ALLY_OUTPUT)/images/playos-ally-usb.img"; \
	if [ ! -f "$$IMAGE" ]; then \
		echo "ERROR: USB image not found at $$IMAGE. Run 'make ally-usb-image' first."; exit 1; \
	fi; \
	sudo dd if="$$IMAGE" of="$$USB_PATH" bs=4M status=progress conv=fsync; \
	echo "==> Flash complete. Safe to remove $$USB_PATH."

# ── Clean targets ────────────────────────────────────────────────────────
.PHONY: clean
clean: ## Remove build output (preserves dl/ cache)
	@rm -rf "$(QEMU_OUTPUT)" "$(ALLY_OUTPUT)"
	@echo "Build output cleaned. dl/ cache preserved."

.PHONY: distclean
distclean: ## Remove everything including dl/ and buildroot/
	@rm -rf "$(QEMU_OUTPUT)" "$(ALLY_OUTPUT)" "$(BUILDROOT_DIR)"
	@echo "Full distclean complete."
