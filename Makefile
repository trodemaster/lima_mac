# Lima macOS VM Management
# Manages three VM instances: macos-26 (release), macos-27-beta (beta), macos-15 (N-1)

.PHONY: build-26 clean-26 rebuild-26 \
        build-27-beta clean-27-beta rebuild-27-beta \
        build-15 clean-15 rebuild-15 \
        build-26-test clean-26-test rebuild-26-test \
        status help

# ── Tool paths ────────────────────────────────────────────────────────────────

LIMACTL         ?= limactl
LIMA_APP_BUNDLE ?= /Applications/MacPorts/Lima.app
GHRUNNER        ?= $(HOME)/Developer/blakeports/scripts/ghrunner

# ── GitHub repository ─────────────────────────────────────────────────────────

GITHUB_OWNER    ?= trodemaster
GITHUB_REPO     ?= blakeports

# ── Build options ─────────────────────────────────────────────────────────────

# Set to 1 to skip OS software update check (speeds up test builds)
SKIP_OS_UPDATE  ?= 0

# Filename of the Xcode .xip archive in lima_mac/xcode/ (e.g. Xcode_27_beta.xip).
# If unset, Xcode install is skipped — CLT will still be installed.
XCODE_XIP       ?=

# Set to 1 to skip cliclick port install (useful on beta OS where it pulls a long
# dependency chain from source — takes 30-60 min with no binary archives available).
SKIP_CLICLICK   ?= 0

# ── Instance definitions ──────────────────────────────────────────────────────

INSTANCE_26      := macos-26
INSTANCE_27_BETA := macos-27-beta
INSTANCE_15      := macos-15
INSTANCE_26_TEST := macos-26-test

CONFIG_26      := $(CURDIR)/macos-26.yaml
CONFIG_27_BETA := $(CURDIR)/macos-27-beta.yaml
CONFIG_15      := $(CURDIR)/macos-15.yaml
CONFIG_26_TEST := $(CURDIR)/macos-26-test.yaml

RUNNER_26      := macOS_26
RUNNER_27_BETA := macOS_27_beta
RUNNER_15      := macOS_15

.DEFAULT_GOAL := help

# Wait for the virtiofs mount (/Volumes/lima_mac) after a reboot.
# The Lima guest agent creates the symlink a few seconds after SSH is reachable.
# Usage: $(call wait_mount,INSTANCE_NAME)
define wait_mount
	@i=0; while ! $(LIMACTL) shell $(1) -- test -f /Volumes/lima_mac/configure.sh 2>/dev/null; do \
		i=$$((i+1)); \
		[ $$i -ge 24 ] && echo "[wait-mount] timed out waiting for virtiofs on $(1)" && exit 1; \
		echo "[wait-mount] not ready yet ($$i/24), retrying in 5s..."; \
		sleep 5; \
	done; echo "[wait-mount] virtiofs mount ready"
endef

# ── macOS 26 (release) ────────────────────────────────────────────────────────

build-26:
	$(LIMACTL) create --tty=false --name=$(INSTANCE_26) $(CONFIG_26)
	$(LIMACTL) start $(INSTANCE_26)
	$(LIMACTL) stop $(INSTANCE_26)
	$(LIMACTL) start $(INSTANCE_26)
	SKIP_OS_UPDATE=$(SKIP_OS_UPDATE) $(CURDIR)/os-update.sh $(INSTANCE_26) $(LIMACTL)
	$(LIMACTL) shell $(INSTANCE_26) env XCODE_XIP=$(XCODE_XIP) /Volumes/lima_mac/developertools.sh
	$(LIMACTL) shell $(INSTANCE_26) env SKIP_CLICLICK=$(SKIP_CLICLICK) /Volumes/lima_mac/macports.sh
	$(CURDIR)/scripts/autologin-reboot.sh $(INSTANCE_26) $(LIMACTL)
	$(call wait_mount,$(INSTANCE_26))
	$(LIMACTL) shell $(INSTANCE_26) /Volumes/lima_mac/configure.sh wallpaper
	$(LIMACTL) shell $(INSTANCE_26) env \
		RUNNER_LABEL=$(RUNNER_26) \
		RUNNER_TOKEN=$$(gh api repos/$(GITHUB_OWNER)/$(GITHUB_REPO)/actions/runners/registration-token --method POST --jq '.token') \
		/Volumes/lima_mac/configure.sh runner

clean-26:
	-$(GHRUNNER) -remove $(RUNNER_26)
	-$(LIMACTL) stop -f $(INSTANCE_26)
	$(LIMACTL) remove -f $(INSTANCE_26)

rebuild-26: clean-26 build-26

# ── macOS 27 Beta ─────────────────────────────────────────────────────────────

build-27-beta:
	$(LIMACTL) create --tty=false --name=$(INSTANCE_27_BETA) $(CONFIG_27_BETA)
	$(LIMACTL) start $(INSTANCE_27_BETA)
	$(LIMACTL) stop $(INSTANCE_27_BETA)
	$(LIMACTL) start $(INSTANCE_27_BETA)
	SKIP_OS_UPDATE=$(SKIP_OS_UPDATE) $(CURDIR)/os-update.sh $(INSTANCE_27_BETA) $(LIMACTL)
	$(LIMACTL) shell $(INSTANCE_27_BETA) env XCODE_XIP=$(XCODE_XIP) /Volumes/lima_mac/developertools.sh
	$(LIMACTL) shell $(INSTANCE_27_BETA) env SKIP_CLICLICK=$(SKIP_CLICLICK) /Volumes/lima_mac/macports.sh
	$(CURDIR)/scripts/autologin-reboot.sh $(INSTANCE_27_BETA) $(LIMACTL)
	$(call wait_mount,$(INSTANCE_27_BETA))
	$(LIMACTL) shell $(INSTANCE_27_BETA) /Volumes/lima_mac/configure.sh wallpaper
	$(LIMACTL) shell $(INSTANCE_27_BETA) env \
		RUNNER_LABEL=$(RUNNER_27_BETA) \
		RUNNER_TOKEN=$$(gh api repos/$(GITHUB_OWNER)/$(GITHUB_REPO)/actions/runners/registration-token --method POST --jq '.token') \
		/Volumes/lima_mac/configure.sh runner

clean-27-beta:
	-$(GHRUNNER) -remove $(RUNNER_27_BETA)
	-$(LIMACTL) stop -f $(INSTANCE_27_BETA)
	$(LIMACTL) remove -f $(INSTANCE_27_BETA)

rebuild-27-beta: clean-27-beta build-27-beta

# ── macOS 15 (Sequoia) ────────────────────────────────────────────────────────

build-15:
	$(LIMACTL) create --tty=false --name=$(INSTANCE_15) $(CONFIG_15)
	$(LIMACTL) start $(INSTANCE_15)
	$(LIMACTL) stop $(INSTANCE_15)
	$(LIMACTL) start $(INSTANCE_15)
	SKIP_OS_UPDATE=$(SKIP_OS_UPDATE) $(CURDIR)/os-update.sh $(INSTANCE_15) $(LIMACTL)
	$(LIMACTL) shell $(INSTANCE_15) env XCODE_XIP=$(XCODE_XIP) /Volumes/lima_mac/developertools.sh
	$(LIMACTL) shell $(INSTANCE_15) env SKIP_CLICLICK=$(SKIP_CLICLICK) /Volumes/lima_mac/macports.sh
	$(CURDIR)/scripts/autologin-reboot.sh $(INSTANCE_15) $(LIMACTL)
	$(call wait_mount,$(INSTANCE_15))
	$(LIMACTL) shell $(INSTANCE_15) /Volumes/lima_mac/configure.sh wallpaper
	$(LIMACTL) shell $(INSTANCE_15) env \
		RUNNER_LABEL=$(RUNNER_15) \
		RUNNER_TOKEN=$$(gh api repos/$(GITHUB_OWNER)/$(GITHUB_REPO)/actions/runners/registration-token --method POST --jq '.token') \
		/Volumes/lima_mac/configure.sh runner

clean-15:
	-$(GHRUNNER) -remove $(RUNNER_15)
	-$(LIMACTL) stop -f $(INSTANCE_15)
	$(LIMACTL) remove -f $(INSTANCE_15)

rebuild-15: clean-15 build-15

# ── macOS 26 test (patch validation — no provisioning) ────────────────────────

build-26-test:
	$(LIMACTL) create --tty=false --name=$(INSTANCE_26_TEST) $(CONFIG_26_TEST)
	$(LIMACTL) start $(INSTANCE_26_TEST)

clean-26-test:
	-$(LIMACTL) stop -f $(INSTANCE_26_TEST)
	$(LIMACTL) remove -f $(INSTANCE_26_TEST)

rebuild-26-test: clean-26-test build-26-test

# ── Status and help ───────────────────────────────────────────────────────────

status:
	$(LIMACTL) list

help:
	@echo "Lima macOS VM Management"
	@echo ""
	@echo "Usage: make [target]"
	@echo ""
	@echo "  build-26        Create, provision, install MacPorts, and register macOS 26 runner"
	@echo "  clean-26        Deregister runner, stop, and remove macOS 26 VM"
	@echo "  rebuild-26      Clean then build macOS 26"
	@echo ""
	@echo "  build-27-beta   Create, provision, install MacPorts, and register macOS 27 Beta runner"
	@echo "  clean-27-beta   Deregister runner, stop, and remove macOS 27 Beta VM"
	@echo "  rebuild-27-beta Clean then build macOS 27 Beta"
	@echo ""
	@echo "  build-15        Create, provision, install MacPorts, and register macOS 15 runner"
	@echo "  clean-15        Deregister runner, stop, and remove macOS 15 VM"
	@echo "  rebuild-15      Clean then build macOS 15"
	@echo ""
	@echo "  build-26-test   Create and start patch-validation VM (no provisioning)"
	@echo "  clean-26-test   Stop and remove patch-validation VM"
	@echo "  rebuild-26-test Clean then build patch-validation VM"
	@echo ""
	@echo "  status          Show all Lima instance states"
	@echo "  help            Show this message"
	@echo ""
	@echo "Overridable variables:"
	@echo "  LIMACTL=$(LIMACTL)"
	@echo "  LIMA_APP_BUNDLE=$(LIMA_APP_BUNDLE)"
	@echo "  GITHUB_OWNER=$(GITHUB_OWNER)"
	@echo "  GITHUB_REPO=$(GITHUB_REPO)"
	@echo "  SKIP_OS_UPDATE=$(SKIP_OS_UPDATE)  (set to 1 to skip OS update check)
  SKIP_CLICLICK=$(SKIP_CLICLICK)    (set to 1 to skip cliclick port install)"
