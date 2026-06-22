# MDM server management for lima-mac
#
# Setup sequence (one-time):
#   1. cp example.envrc .envrc  — fill in Vault address, secrets, and MDM_HOST_IP
#   2. make install               — go install nanomdm and scepserver binaries
#   3. sudo port install caddy    — TLS reverse proxy
#   4. make setup-ca              — generate SCEP CA key locally, sign CSR with Vault
#   5. make setup-tls             — issue TLS cert from Vault, generate Caddyfile
#   6. make install-launchd       — install LaunchAgent plists
#   7. make load                  — start all three services
#   8. <get APNS cert from Apple> — see README / make help-apns
#   9. make push-cert APNS_CERT=push.pem APNS_KEY=push.key
#  10. Set MDM_PUSH_TOPIC in .envrc, then: make enroll INSTANCE=macos-26

.PHONY: install setup-ca setup-tls setup install-launchd \
        load unload restart status logs \
        push-cert gen-profile enroll unenroll \
        help help-apns

MDM_DIR        := $(CURDIR)
DATA_DIR       := $(MDM_DIR)/data
SCRIPTS_DIR    := $(MDM_DIR)/scripts
LAUNCHD_DIR    := $(MDM_DIR)/launchd
LAUNCH_AGENTS  := $(HOME)/Library/LaunchAgents
LIMACTL        ?= limactl

SCEP_LABEL     := com.lima-mac.scepserver
NANOMDM_LABEL  := com.lima-mac.nanomdm
CADDY_LABEL    := com.lima-mac.caddy

SCEP_PLIST     := $(LAUNCH_AGENTS)/$(SCEP_LABEL).plist
NANOMDM_PLIST  := $(LAUNCH_AGENTS)/$(NANOMDM_LABEL).plist
CADDY_PLIST    := $(LAUNCH_AGENTS)/$(CADDY_LABEL).plist

.DEFAULT_GOAL := help

# ── Installation ──────────────────────────────────────────────────────────────

install:
	go install github.com/micromdm/scep/v2/cmd/scepserver@latest
	go install github.com/micromdm/nanomdm/cmd/nanomdm@latest
	@echo ""
	@echo "Binaries installed to $$(go env GOPATH)/bin/"
	@echo "Install caddy if not present: sudo port install caddy"

# ── CA and TLS setup ─────────────────────────────────────────────────────────

setup-ca:
	@test -f $(MDM_DIR)/.envrc || (echo "ERROR: copy example.envrc to .envrc and populate it" && exit 1)
	bash $(SCRIPTS_DIR)/setup-ca.sh

setup-tls:
	@test -f $(MDM_DIR)/.envrc || (echo "ERROR: copy example.envrc to .envrc and populate it" && exit 1)
	bash $(SCRIPTS_DIR)/setup-tls.sh

setup: setup-ca setup-tls

# ── LaunchAgent management ───────────────────────────────────────────────────

install-launchd: $(LAUNCH_AGENTS)
	@mkdir -p $(DATA_DIR)/logs
	sed 's|%%MDM_DIR%%|$(MDM_DIR)|g' $(LAUNCHD_DIR)/$(SCEP_LABEL).plist.template  > $(SCEP_PLIST)
	sed 's|%%MDM_DIR%%|$(MDM_DIR)|g' $(LAUNCHD_DIR)/$(NANOMDM_LABEL).plist.template > $(NANOMDM_PLIST)
	sed 's|%%MDM_DIR%%|$(MDM_DIR)|g' $(LAUNCHD_DIR)/$(CADDY_LABEL).plist.template  > $(CADDY_PLIST)
	@echo "LaunchAgent plists installed to $(LAUNCH_AGENTS)"
	@echo "Run: make load"

$(LAUNCH_AGENTS):
	mkdir -p $(LAUNCH_AGENTS)

load:
	launchctl load -w $(SCEP_PLIST)
	launchctl load -w $(NANOMDM_PLIST)
	launchctl load -w $(CADDY_PLIST)
	@echo "Services loaded — check status with: make status"

unload:
	-launchctl unload $(CADDY_PLIST)
	-launchctl unload $(NANOMDM_PLIST)
	-launchctl unload $(SCEP_PLIST)

restart: unload load

status:
	@echo "=== scepserver ===" && launchctl list | grep $(SCEP_LABEL)   || echo "  not loaded"
	@echo "=== nanomdm ===" && launchctl list | grep $(NANOMDM_LABEL) || echo "  not loaded"
	@echo "=== caddy ===" && launchctl list | grep $(CADDY_LABEL)    || echo "  not loaded"

logs:
	@echo "=== scepserver ===" && tail -20 $(DATA_DIR)/logs/scepserver.log 2>/dev/null || echo "  no log yet"
	@echo "=== nanomdm ===" && tail -20 $(DATA_DIR)/logs/nanomdm.log 2>/dev/null || echo "  no log yet"
	@echo "=== caddy ===" && tail -20 $(DATA_DIR)/logs/caddy.log 2>/dev/null || echo "  no log yet"

# ── Push certificate (APNS) ──────────────────────────────────────────────────

# Upload APNS push cert + key to NanoMDM.
# Usage: make push-cert APNS_CERT=path/to/push.pem APNS_KEY=path/to/push.key
push-cert:
	@test -n "$(APNS_CERT)" || (echo "ERROR: specify APNS_CERT=path/to/push.pem" && exit 1)
	@test -n "$(APNS_KEY)"  || (echo "ERROR: specify APNS_KEY=path/to/push.key"  && exit 1)
	@source $(MDM_DIR)/.envrc && \
		cat $(APNS_CERT) $(APNS_KEY) | \
		curl -s -X PUT \
			-u ":$$MDM_API_KEY" \
			--data-binary @- \
			"http://127.0.0.1:$$MDM_HTTP_PORT/v1/pushcert" && \
		echo "" && echo "Push cert uploaded. Set MDM_PUSH_TOPIC in .envrc from the output above."

# ── Enrollment ────────────────────────────────────────────────────────────────

gen-profile:
	bash $(SCRIPTS_DIR)/gen-profile.sh

# Push enrollment profile to a Lima VM.
# Usage: make enroll INSTANCE=macos-26
enroll: gen-profile
	@test -n "$(INSTANCE)" || (echo "ERROR: specify INSTANCE=<vm-name>" && exit 1)
	$(LIMACTL) shell $(INSTANCE) -- bash -c 'cat > /tmp/enroll.mobileconfig' \
		< $(DATA_DIR)/enroll.mobileconfig
	$(LIMACTL) shell $(INSTANCE) -- sudo profiles install -path /tmp/enroll.mobileconfig
	$(LIMACTL) shell $(INSTANCE) -- rm /tmp/enroll.mobileconfig
	@echo "Enrolled $(INSTANCE). Check NanoMDM logs: make logs"

# Remove MDM enrollment from a VM before rebuild.
# Usage: make unenroll INSTANCE=macos-26
unenroll:
	@test -n "$(INSTANCE)" || (echo "ERROR: specify INSTANCE=<vm-name>" && exit 1)
	$(LIMACTL) shell $(INSTANCE) -- sudo profiles remove -identifier com.lima-mac.mdm.enrollment
	@echo "Unenrolled $(INSTANCE)"

# ── Help ─────────────────────────────────────────────────────────────────────

help:
	@echo "MDM server management for lima-mac"
	@echo ""
	@echo "Setup (one-time):"
	@echo "  install            go install nanomdm and scepserver"
	@echo "  setup-ca           generate SCEP CA key + Vault-signed cert"
	@echo "  setup-tls          issue TLS cert from Vault, write Caddyfile"
	@echo "  setup              setup-ca + setup-tls"
	@echo "  install-launchd    install LaunchAgent plists to ~/Library/LaunchAgents"
	@echo ""
	@echo "Service control:"
	@echo "  load               launchctl load all three agents"
	@echo "  unload             launchctl unload all three agents"
	@echo "  restart            unload then load"
	@echo "  status             show launchctl status for each service"
	@echo "  logs               tail last 20 lines of each service log"
	@echo ""
	@echo "Enrollment:"
	@echo "  push-cert APNS_CERT=f APNS_KEY=f   upload APNS push cert to nanomdm"
	@echo "  gen-profile                          render enroll.mobileconfig from template"
	@echo "  enroll INSTANCE=macos-26             install enrollment profile in VM"
	@echo "  unenroll INSTANCE=macos-26           remove MDM from VM (before rebuild)"
	@echo ""
	@echo "  help-apns          APNS cert acquisition notes"

help-apns:
	@echo "Getting an APNS push certificate for MDM:"
	@echo ""
	@echo "1. You need an Apple Developer account."
	@echo ""
	@echo "2. Get a vendor CSR signed by Apple's MDM vendor certificate."
	@echo "   The mdmcert.download tool from the MicroMDM project automates this:"
	@echo "     go install github.com/micromdm/micromdm/tools/mdmcert-download@latest"
	@echo "     mdmcert-download -email <your@email> -password <password>"
	@echo ""
	@echo "3. Upload the resulting CSR at https://identity.apple.com/pushcert"
	@echo "   Download the signed push cert (.pem)."
	@echo ""
	@echo "4. Upload to NanoMDM:"
	@echo "     make push-cert APNS_CERT=push.pem APNS_KEY=push.key"
	@echo ""
	@echo "5. The push topic is printed in the upload response."
	@echo "   Set MDM_PUSH_TOPIC in .envrc, then: make enroll INSTANCE=<name>"
	@echo ""
	@echo "Push certs expire annually — renew at https://identity.apple.com/pushcert"
