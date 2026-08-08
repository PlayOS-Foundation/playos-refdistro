# PlayOS Reference Distribution — Developer Makefile
#
# Usage:
#   make setup        Clone Buildroot, check dependencies
#   make qemu-config  Open menuconfig for QEMU target
#   make qemu-build   Full image build for QEMU
#   make qemu-run     Boot image in QEMU/OVMF
#   make clean        Remove build output (preserves dl/ cache)
#   make distclean    Remove everything including dl/
#
# This Makefile wraps Buildroot's build system with PlayOS conventions.

# ── Paths ────────────────────────────────────────────────────────────────
BR2_EXTERNAL := $(CURDIR)/br2-external
BUILDROOT_DIR := $(CURDIR)/buildroot
QEMU_DEFCONFIG := $(BR2_EXTERNAL)/configs/playos_qemu_x86_64_defconfig
QEMU_OUTPUT := $(CURDIR)/output/qemu
SCRIPTS_DIR := $(CURDIR)/scripts

# Source shared logging (if present)
-include $(SCRIPTS_DIR)/lib/playos_log.mk

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

# ── ROG Ally targets (stubs — Sprint 3) ──────────────────────────────────
.PHONY: ally-config
ally-config: ## Open menuconfig for ROG Ally target (stub — Sprint 3)
	@echo "ROG Ally config is not yet implemented. See Sprint 3."

.PHONY: ally-build
ally-build: ## Full image build for ROG Ally (stub — Sprint 3)
	@echo "ROG Ally build is not yet implemented. See Sprint 3."

.PHONY: ally-flash
ally-flash: ## Flash image to USB drive (stub — Sprint 3)
	@echo "ROG Ally flash is not yet implemented. See Sprint 3."

# ── Clean targets ────────────────────────────────────────────────────────
.PHONY: clean
clean: ## Remove build output (preserves dl/ cache)
	@rm -rf "$(QEMU_OUTPUT)"
	@echo "Build output cleaned. dl/ cache preserved."

.PHONY: distclean
distclean: ## Remove everything including dl/ and buildroot/
	@rm -rf "$(QEMU_OUTPUT)" "$(BUILDROOT_DIR)"
	@echo "Full distclean complete."
