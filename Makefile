# Lima macOS VM Management
# Manages four VM instances: macos-27, macos-26, macos-15 (N-2), macos-14 (N-3)

.PHONY: build-26 clean-26 rebuild-26 \
        build-27 clean-27 rebuild-27 \
        build-15 clean-15 rebuild-15 \
        build-14 clean-14 rebuild-14 \
        build-26-test clean-26-test rebuild-26-test \
        build-15-test clean-15-test rebuild-15-test \
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

# Filename of the Xcode .xip archive in lima_mac/xcode/ (e.g. Xcode_27.xip).
# If unset, Xcode install is skipped — CLT will still be installed.
XCODE_XIP       ?=

# Set to 1 to skip cliclick port install (useful on beta OS where it pulls a long
# dependency chain from source — takes 30-60 min with no binary archives available).
SKIP_CLICLICK   ?= 0

# Set to 1 to skip developertools.sh and macports.sh entirely (speeds up test
# builds when only configure.sh changes need to be validated).
SKIP_MACPORTS   ?= 0

# ── Instance definitions ──────────────────────────────────────────────────────

INSTANCE_26      := macos-26
INSTANCE_27      := macos-27
INSTANCE_15      := macos-15
INSTANCE_14      := macos-14
INSTANCE_26_TEST := macos-26-test
INSTANCE_15_TEST := macos-15-test

CONFIG_26      := $(CURDIR)/macos-26.yaml
CONFIG_27      := $(CURDIR)/macos-27.yaml
CONFIG_15      := $(CURDIR)/macos-15.yaml
CONFIG_14      := $(CURDIR)/macos-14.yaml
CONFIG_26_TEST := $(CURDIR)/macos-26-test.yaml
CONFIG_15_TEST := $(CURDIR)/macos-15-test.yaml

RUNNER_26      := macOS_26
RUNNER_27      := macOS_27
RUNNER_15      := macOS_15
RUNNER_14      := macOS_14

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
	@[ "$(SKIP_MACPORTS)" = "1" ] || $(LIMACTL) shell $(INSTANCE_26) env XCODE_XIP=$(XCODE_XIP) /Volumes/lima_mac/developertools.sh
	@[ "$(SKIP_MACPORTS)" = "1" ] || $(LIMACTL) shell $(INSTANCE_26) env SKIP_CLICLICK=$(SKIP_CLICLICK) /Volumes/lima_mac/macports.sh
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

# ── macOS 27 ──────────────────────────────────────────────────────────────────

build-27:
	$(LIMACTL) create --tty=false --name=$(INSTANCE_27) $(CONFIG_27)
	$(LIMACTL) start $(INSTANCE_27)
	$(LIMACTL) stop $(INSTANCE_27)
	$(LIMACTL) start $(INSTANCE_27)
	SKIP_OS_UPDATE=$(SKIP_OS_UPDATE) $(CURDIR)/os-update.sh $(INSTANCE_27) $(LIMACTL)
	@[ "$(SKIP_MACPORTS)" = "1" ] || $(LIMACTL) shell $(INSTANCE_27) env XCODE_XIP=$(XCODE_XIP) /Volumes/lima_mac/developertools.sh
	@[ "$(SKIP_MACPORTS)" = "1" ] || $(LIMACTL) shell $(INSTANCE_27) env SKIP_CLICLICK=$(SKIP_CLICLICK) /Volumes/lima_mac/macports.sh
	$(CURDIR)/scripts/autologin-reboot.sh $(INSTANCE_27) $(LIMACTL)
	$(call wait_mount,$(INSTANCE_27))
	$(LIMACTL) shell $(INSTANCE_27) /Volumes/lima_mac/configure.sh wallpaper
	$(LIMACTL) shell $(INSTANCE_27) env \
		RUNNER_LABEL=$(RUNNER_27) \
		RUNNER_TOKEN=$$(gh api repos/$(GITHUB_OWNER)/$(GITHUB_REPO)/actions/runners/registration-token --method POST --jq '.token') \
		/Volumes/lima_mac/configure.sh runner

clean-27:
	-$(GHRUNNER) -remove $(RUNNER_27)
	-$(LIMACTL) stop -f $(INSTANCE_27)
	$(LIMACTL) remove -f $(INSTANCE_27)

rebuild-27: clean-27 build-27

# ── macOS 15 (Sequoia) ────────────────────────────────────────────────────────

build-15:
	$(LIMACTL) create --tty=false --name=$(INSTANCE_15) $(CONFIG_15)
	$(LIMACTL) start $(INSTANCE_15)
	$(LIMACTL) stop $(INSTANCE_15)
	$(LIMACTL) start $(INSTANCE_15)
	SKIP_OS_UPDATE=$(SKIP_OS_UPDATE) $(CURDIR)/os-update.sh $(INSTANCE_15) $(LIMACTL)
	@[ "$(SKIP_MACPORTS)" = "1" ] || $(LIMACTL) shell $(INSTANCE_15) env XCODE_XIP=$(XCODE_XIP) /Volumes/lima_mac/developertools.sh
	@[ "$(SKIP_MACPORTS)" = "1" ] || $(LIMACTL) shell $(INSTANCE_15) env SKIP_CLICLICK=$(SKIP_CLICLICK) /Volumes/lima_mac/macports.sh
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

# ── macOS 14 (Sonoma) ────────────────────────────────────────────────────────

build-14:
	$(LIMACTL) create --tty=false --name=$(INSTANCE_14) $(CONFIG_14)
	$(LIMACTL) start $(INSTANCE_14)
	$(LIMACTL) stop $(INSTANCE_14)
	$(LIMACTL) start $(INSTANCE_14)
	SKIP_OS_UPDATE=$(SKIP_OS_UPDATE) $(CURDIR)/os-update.sh $(INSTANCE_14) $(LIMACTL)
	@[ "$(SKIP_MACPORTS)" = "1" ] || $(LIMACTL) shell $(INSTANCE_14) env XCODE_XIP=$(XCODE_XIP) /Volumes/lima_mac/developertools.sh
	@[ "$(SKIP_MACPORTS)" = "1" ] || $(LIMACTL) shell $(INSTANCE_14) env SKIP_CLICLICK=$(SKIP_CLICLICK) /Volumes/lima_mac/macports.sh
	$(CURDIR)/scripts/autologin-reboot.sh $(INSTANCE_14) $(LIMACTL)
	$(call wait_mount,$(INSTANCE_14))
	$(LIMACTL) shell $(INSTANCE_14) /Volumes/lima_mac/configure.sh wallpaper
	$(LIMACTL) shell $(INSTANCE_14) env \
		RUNNER_LABEL=$(RUNNER_14) \
		RUNNER_TOKEN=$$(gh api repos/$(GITHUB_OWNER)/$(GITHUB_REPO)/actions/runners/registration-token --method POST --jq '.token') \
		/Volumes/lima_mac/configure.sh runner

clean-14:
	-$(GHRUNNER) -remove $(RUNNER_14)
	-$(LIMACTL) stop -f $(INSTANCE_14)
	$(LIMACTL) remove -f $(INSTANCE_14)

rebuild-14: clean-14 build-14

# ── macOS 26 test (patch validation — no provisioning) ────────────────────────

build-26-test:
	$(LIMACTL) create --tty=false --name=$(INSTANCE_26_TEST) $(CONFIG_26_TEST)
	$(LIMACTL) start $(INSTANCE_26_TEST)

clean-26-test:
	-$(LIMACTL) stop -f $(INSTANCE_26_TEST)
	$(LIMACTL) remove -f $(INSTANCE_26_TEST)

rebuild-26-test: clean-26-test build-26-test

# ── macOS 15 test (patch validation — no provisioning) ────────────────────────

build-15-test:
	$(LIMACTL) create --tty=false --name=$(INSTANCE_15_TEST) $(CONFIG_15_TEST)
	$(LIMACTL) start $(INSTANCE_15_TEST)

clean-15-test:
	-$(LIMACTL) stop -f $(INSTANCE_15_TEST)
	$(LIMACTL) remove -f $(INSTANCE_15_TEST)

rebuild-15-test: clean-15-test build-15-test

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
	@echo "  build-27        Create, provision, install MacPorts, and register macOS 27 runner"
	@echo "  clean-27        Deregister runner, stop, and remove macOS 27 VM"
	@echo "  rebuild-27      Clean then build macOS 27"
	@echo ""
	@echo "  build-15        Create, provision, install MacPorts, and register macOS 15 runner"
	@echo "  clean-15        Deregister runner, stop, and remove macOS 15 VM"
	@echo "  rebuild-15      Clean then build macOS 15"
	@echo ""
	@echo "  build-26-test   Create and start patch-validation VM (no provisioning)"
	@echo "  clean-26-test   Stop and remove patch-validation VM"
	@echo "  rebuild-26-test Clean then build patch-validation VM"
	@echo ""
	@echo "  build-14        Create, provision, install MacPorts, and register macOS 14 runner"
	@echo "  clean-14        Deregister runner, stop, and remove macOS 14 VM"
	@echo "  rebuild-14      Clean then build macOS 14"
	@echo ""
	@echo "  build-15-test   Create and start macOS 15 patch-validation VM (no provisioning)"
	@echo "  clean-15-test   Stop and remove macOS 15 patch-validation VM"
	@echo "  rebuild-15-test Clean then build macOS 15 patch-validation VM"
	@echo ""
	@echo "  status          Show all Lima instance states"
	@echo "  help            Show this message"
	@echo ""
	@echo "Overridable variables:"
	@echo "  LIMACTL=$(LIMACTL)"
	@echo "  LIMA_APP_BUNDLE=$(LIMA_APP_BUNDLE)"
	@echo "  GITHUB_OWNER=$(GITHUB_OWNER)"
	@echo "  GITHUB_REPO=$(GITHUB_REPO)"
	@echo "  SKIP_OS_UPDATE=$(SKIP_OS_UPDATE)   (set to 1 to skip OS update check)"
	@echo "  SKIP_CLICLICK=$(SKIP_CLICLICK)    (set to 1 to skip cliclick port install)"
	@echo "  SKIP_MACPORTS=$(SKIP_MACPORTS)    (set to 1 to skip developertools.sh + macports.sh entirely)"
