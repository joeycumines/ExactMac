# make/exactmac.mk — local ExactMacServer deployment for macOS.
#
# This GNU Make module builds the Swift gRPC server and Go MCP proxy, packages
# the server as a real .app (including SwiftPM resource bundles), signs it,
# registers it with LaunchServices, and runs it as a per-user LaunchAgent.
#
# The default signing identity is ad hoc (`-`) for zero-configuration local
# development.  TCC permissions are more stable when the app is signed with a
# persistent Apple Development identity:
#
#   gmake exactmac.install \
#     EXACTMAC_SIGN_IDENTITY='Apple Development: Your Name (TEAMID)'
#
# Low-level phase targets are intentionally independent.  For example,
# `exactmac.register` registers the existing app and does not rebuild or
# re-sign it.  `exactmac.install` is the ordered orchestration target.

# Capture this file while it is the last parsed makefile.  Unlike `pwd` or
# `git rev-parse`, this remains correct when make is invoked from a subdirectory
# or the source tree is not a Git worktree.
EXACTMAC_MAKEFILE := $(lastword $(MAKEFILE_LIST))
PROJECT_ROOT ?= $(abspath $(dir $(EXACTMAC_MAKEFILE))/..)

# --- Product and installation paths -----------------------------------------

EXACTMAC_APP_NAME       ?= ExactMacServer
EXACTMAC_BUNDLE_ID      ?= io.github.joeycumines.exactmac.server
EXACTMAC_VERSION        ?= 0.1.0
EXACTMAC_BUILD_VERSION  ?= 1
EXACTMAC_MIN_MACOS      ?= 15.0

EXACTMAC_APP_DIR        ?= $(HOME)/Applications/$(EXACTMAC_APP_NAME).app
EXACTMAC_APP_EXECUTABLE := $(EXACTMAC_APP_DIR)/Contents/MacOS/$(EXACTMAC_APP_NAME)
EXACTMAC_STAGING_DIR    := $(EXACTMAC_APP_DIR).staging

EXACTMAC_SERVER_BUILD_DIR        ?= $(PROJECT_ROOT)/Server/.build/release
EXACTMAC_SERVER_BIN              ?= $(EXACTMAC_SERVER_BUILD_DIR)/$(EXACTMAC_APP_NAME)
EXACTMAC_RESOURCE_BUNDLE_NAME    ?= ExactMacServer_ExactMacServer.bundle
EXACTMAC_REQUIRED_RESOURCE_BUNDLE := $(EXACTMAC_SERVER_BUILD_DIR)/$(EXACTMAC_RESOURCE_BUNDLE_NAME)

EXACTMAC_PLIST          ?= $(HOME)/Library/LaunchAgents/$(EXACTMAC_BUNDLE_ID).plist
EXACTMAC_SOCKET         ?= $(HOME)/Library/Caches/exactmac.sock
# The consent channel, in the same owner-only state directory as the grant store and the audit
# log. It is set HERE and not defaulted in the server, because an absent channel is a
# deliberate fail-closed configuration: a server without one refuses every consent-requiring
# capability, and a server that went looking for a channel nobody configured would bind a
# socket it had no reason to own.
EXACTMAC_CONSOLE_SOCKET  ?= $(HOME)/.exactmac/console.sock
EXACTMAC_STDOUT_LOG     ?= $(HOME)/Library/Logs/exactmac.log
EXACTMAC_STDERR_LOG     ?= $(HOME)/Library/Logs/exactmac.error.log

EXACTMAC_BUILD_LOG_DIR  ?= $(PROJECT_ROOT)/.build-logs
EXACTMAC_SERVER_BUILD_LOG ?= $(EXACTMAC_BUILD_LOG_DIR)/exactmac-server.log
EXACTMAC_MCP_BUILD_LOG    ?= $(EXACTMAC_BUILD_LOG_DIR)/exactmac.log

EXACTMAC_SIGN_IDENTITY  ?= -
EXACTMAC_WAIT_ATTEMPTS  ?= 10
EXACTMAC_WAIT_INTERVAL  ?= 1

EXACTMAC_UID            := $(shell id -u)
EXACTMAC_LAUNCH_DOMAIN  := gui/$(EXACTMAC_UID)
EXACTMAC_SERVICE_TARGET := $(EXACTMAC_LAUNCH_DOMAIN)/$(EXACTMAC_BUNDLE_ID)

# Go installs commands into GOBIN, or the first GOPATH/bin when GOBIN is empty.
# Resolve that once so build, documentation output, verification, and uninstall
# all refer to the same binary.  The fallback is Go's default GOPATH location.
EXACTMAC_GO_BIN_DIR ?= $(strip $(shell \
	gobin="$$(go env GOBIN 2>/dev/null)"; \
	if [ -z "$$gobin" ]; then \
		gopath="$$(go env GOPATH 2>/dev/null)"; \
		gobin="$${gopath%%:*}/bin"; \
	fi; \
	if [ -n "$$gobin" ]; then printf '%s' "$$gobin"; else printf '%s' "$(HOME)/go/bin"; fi))
EXACTMAC_MCP_BIN ?= $(EXACTMAC_GO_BIN_DIR)/exactmac
EXACTMAC_MCP_BIN_DIR := $(patsubst %/,%,$(dir $(EXACTMAC_MCP_BIN)))

# LaunchServices registration tool supplied by macOS.
EXACTMAC_LSREGISTER ?= /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# --- Embedded plist contents ------------------------------------------------

# LSUIElement keeps this background server out of the Dock and app switcher.
define EXACTMAC_INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$(EXACTMAC_APP_NAME)</string>
    <key>CFBundleExecutable</key>
    <string>$(EXACTMAC_APP_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(EXACTMAC_BUNDLE_ID)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(EXACTMAC_APP_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(EXACTMAC_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(EXACTMAC_BUILD_VERSION)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(EXACTMAC_MIN_MACOS)</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
endef

# This is a LaunchAgent, not a LaunchDaemon: ScreenCaptureKit, AppKit,
# Accessibility, Vision, and Metal must run in the logged-in user's GUI domain.
# KeepAlive=true also implies RunAtLoad. The 0077 umask keeps files and
# directories owner-only while preserving the execute/search bit required by
# macOS framework cache trees. launchd supervises the PROCESS and nothing else:
# there is deliberately no Sockets key, because the server binds its own Unix
# socket. It has to, because reading the caller's pid is the only way it can
# know who is calling, that read happens at accept, and SwiftNIO can only accept
# from a socket it bound itself. A pathname left by a crashed server is taken
# over under a lock the kernel releases when the holder dies, so a restart needs
# no operator; a pathname a live server holds is refused, and refused is
# non-destructive. ThrottleInterval bounds KeepAlive restarts so a repeated fatal
# error cannot spin a tight crash loop.
define EXACTMAC_LAUNCHD_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$(EXACTMAC_BUNDLE_ID)</string>
    <key>ProgramArguments</key>
    <array>
        <string>$(EXACTMAC_APP_EXECUTABLE)</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>GRPC_UNIX_SOCKET</key>
        <string>$(EXACTMAC_SOCKET)</string>
        <key>EXACTMAC_CONSOLE_SOCKET</key>
        <string>$(EXACTMAC_CONSOLE_SOCKET)</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>Umask</key>
    <integer>63</integer>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>$(EXACTMAC_BUNDLE_ID)</string>
    </array>
    <key>StandardOutPath</key>
    <string>$(EXACTMAC_STDOUT_LOG)</string>
    <key>StandardErrorPath</key>
    <string>$(EXACTMAC_STDERR_LOG)</string>
</dict>
</plist>
endef

# Export multiline values for a single shell invocation.  Quoting the expanded
# environment variable preserves all newlines and XML punctuation.
# Reject values that would be unsafe when interpolated into generated XML or
# make recipes. This is a make-time check: hostile backticks, `$()` text, shell
# separators, and XML delimiters are rejected before any recipe is expanded.
EXACTMAC_BACKTICK := `
define EXACTMAC_VALIDATE_VALUE
$(if $(findstring <,$(1)),$(error $(2) contains '<'; refusing unsafe deployment value))
$(if $(findstring >,$(1)),$(error $(2) contains '>'; refusing unsafe deployment value))
$(if $(findstring &,$(1)),$(error $(2) contains '&'; refusing unsafe deployment value))
$(if $(findstring ",$(1)),$(error $(2) contains a quote; refusing unsafe deployment value))
$(if $(findstring $(EXACTMAC_BACKTICK),$(1)),$(error $(2) contains a backtick; refusing unsafe deployment value))
$(if $(findstring ;,$(1)),$(error $(2) contains ';'; refusing unsafe deployment value))
$(if $(findstring |,$(1)),$(error $(2) contains '|'; refusing unsafe deployment value))
$(if $(findstring $$,$(1)),$(error $(2) contains '$$'; refusing unsafe deployment value))
endef
define EXACTMAC_VALIDATE_CONFIG
$(if $(filter command line environment environment-overrides,$(origin $(1))),$(call EXACTMAC_VALIDATE_VALUE,$(value $(1)),$(1)),$(call EXACTMAC_VALIDATE_VALUE,$($(1)),$(1)))
endef
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_APP_NAME))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_BUNDLE_ID))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_VERSION))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_BUILD_VERSION))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_MIN_MACOS))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_APP_DIR))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_APP_EXECUTABLE))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_PLIST))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_SOCKET))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_SOCKET))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_STDOUT_LOG))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_STDERR_LOG))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_SERVER_BUILD_DIR))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_SERVER_BIN))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_RESOURCE_BUNDLE_NAME))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_BUILD_LOG_DIR))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_SERVER_BUILD_LOG))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_MCP_BUILD_LOG))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_MCP_BIN))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_GO_BIN_DIR))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_LSREGISTER))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_SIGN_IDENTITY))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_WAIT_ATTEMPTS))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_WAIT_INTERVAL))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,PROJECT_ROOT))

# Derived values are expanded from validated inputs; validate their expanded
# result as well for defense in depth.
$(eval $(call EXACTMAC_VALIDATE_VALUE,$(EXACTMAC_APP_EXECUTABLE),EXACTMAC_APP_EXECUTABLE))
$(eval $(call EXACTMAC_VALIDATE_VALUE,$(EXACTMAC_PLIST),EXACTMAC_PLIST))
$(eval $(call EXACTMAC_VALIDATE_VALUE,$(EXACTMAC_STAGING_DIR),EXACTMAC_STAGING_DIR))
$(eval $(call EXACTMAC_VALIDATE_VALUE,$(EXACTMAC_REQUIRED_RESOURCE_BUNDLE),EXACTMAC_REQUIRED_RESOURCE_BUNDLE))
$(eval $(call EXACTMAC_VALIDATE_VALUE,$(EXACTMAC_MCP_BIN_DIR),EXACTMAC_MCP_BIN_DIR))
$(eval $(call EXACTMAC_VALIDATE_VALUE,$(EXACTMAC_SERVICE_TARGET),EXACTMAC_SERVICE_TARGET))

export EXACTMAC_INFO_PLIST_E := $(EXACTMAC_INFO_PLIST)
export EXACTMAC_LAUNCHD_PLIST_E := $(EXACTMAC_LAUNCHD_PLIST)
# Export user-configurable XML inputs as data; recipes read these through shell
# variables after the make-time safety gate above.
export EXACTMAC_APP_NAME EXACTMAC_BUNDLE_ID EXACTMAC_VERSION EXACTMAC_BUILD_VERSION
export EXACTMAC_MIN_MACOS EXACTMAC_APP_EXECUTABLE EXACTMAC_SOCKET EXACTMAC_CONSOLE_SOCKET
export EXACTMAC_STDOUT_LOG EXACTMAC_STDERR_LOG

# Only the two piped build recipes need Bash's pipefail.  `private` prevents
# SHELL from leaking into their prerequisite targets.
exactmac.build-server exactmac.build-mcp: private SHELL := /bin/bash

# =============================================================================
# Build
# =============================================================================

##@ [ExactMac] Build

.PHONY: exactmac.doctor
exactmac.doctor: ## Check the local deployment toolchain and source layout.
	@failed=0; \
	pass() { printf '  PASS  %s\n' "$$1"; }; \
	fail() { printf '  FAIL  %s\n' "$$1" >&2; failed=1; }; \
	printf '%s\n' '=== ExactMac deployment doctor ==='; \
	if [ "$$(uname -s)" = Darwin ]; then pass 'host operating system is macOS'; else fail 'host operating system is not macOS'; fi; \
	make_major='$(word 1,$(subst ., ,$(MAKE_VERSION)))'; \
	if [ "$$make_major" -ge 4 ] 2>/dev/null; then pass "GNU Make $(MAKE_VERSION)"; else fail "GNU Make 4+ required (found $(MAKE_VERSION))"; fi; \
	for command_name in swift go buf codesign plutil launchctl xattr ditto tccutil; do \
		if command -v "$$command_name" >/dev/null 2>&1; then pass "command available: $$command_name"; else fail "missing command: $$command_name"; fi; \
	done; \
	if [ -x "$(EXACTMAC_LSREGISTER)" ]; then pass 'LaunchServices registration tool is available'; else fail "missing lsregister: $(EXACTMAC_LSREGISTER)"; fi; \
	if [ -f "$(PROJECT_ROOT)/Server/Package.swift" ]; then pass 'Server/Package.swift exists'; else fail 'Server/Package.swift is missing'; fi; \
	if [ -f "$(PROJECT_ROOT)/go.mod" ]; then pass 'go.mod exists'; else fail 'go.mod is missing'; fi; \
	if command -v sw_vers >/dev/null 2>&1; then \
		macos_version=$$(sw_vers -productVersion); macos_major=$${macos_version%%.*}; \
		if [ "$$macos_major" -ge 15 ] 2>/dev/null; then pass "macOS $$macos_version"; else fail "macOS 15+ required (found $$macos_version)"; fi; \
	fi; \
	if command -v swift >/dev/null 2>&1; then swift --version | sed -n '1p'; fi; \
	if command -v go >/dev/null 2>&1; then \
		go version; \
		if [ -f "$(PROJECT_ROOT)/go.mod" ]; then printf '  module Go directive: '; awk '$$1 == "go" { print $$2; exit }' "$(PROJECT_ROOT)/go.mod"; fi; \
	fi; \
	if [ "$$failed" -ne 0 ]; then printf '%s\n' 'Doctor checks failed.' >&2; exit 1; fi; \
	printf '%s\n' 'Doctor checks passed.'

.PHONY: exactmac.build-server
exactmac.build-server: ## Build the release Swift server and its resource bundle.
	@set -uo pipefail; \
	if ! mkdir -p "$(EXACTMAC_BUILD_LOG_DIR)"; then printf '%s\n' 'ERROR: failed to create build log directory.' >&2; exit 1; fi; \
	printf '%s\n' '=== Building ExactMacServer (release) ==='; \
	if ! $(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory buf.descriptor-sets; then printf '%s\n' 'ERROR: descriptor generation failed.' >&2; exit 1; fi; \
	if ! cd "$(PROJECT_ROOT)/Server"; then printf '%s\n' 'ERROR: Server project directory is unavailable.' >&2; exit 1; fi; \
	if ! swift build --configuration release 2>&1 | tee "$(EXACTMAC_SERVER_BUILD_LOG)" | tail -n 40; then printf '%s\n' 'ERROR: Swift server build failed.' >&2; exit 1; fi; \
	test -x "$(EXACTMAC_SERVER_BIN)" || { printf 'ERROR: server binary missing: %s\n' "$(EXACTMAC_SERVER_BIN)" >&2; exit 1; }; \
	if [ ! -d "$(EXACTMAC_REQUIRED_RESOURCE_BUNDLE)" ]; then \
		printf 'ERROR: SwiftPM resource bundle missing: %s\n' "$(EXACTMAC_REQUIRED_RESOURCE_BUNDLE)" >&2; \
		exit 1; \
	fi; \
	if ! find "$(EXACTMAC_REQUIRED_RESOURCE_BUNDLE)" -type f -name '*.pb' -print -quit | grep -q .; then \
		printf 'ERROR: no protobuf descriptor set (*.pb) was packaged in %s\n' "$(EXACTMAC_REQUIRED_RESOURCE_BUNDLE)" >&2; \
		exit 1; \
	fi; \
	printf 'Server binary: %s\n' "$(EXACTMAC_SERVER_BIN)"; \
	printf 'Resource bundle: %s\n' "$(EXACTMAC_REQUIRED_RESOURCE_BUNDLE)"

.PHONY: exactmac.build-mcp
exactmac.build-mcp: ## Build and install the exactmac CLI (MCP served via `exactmac mcp`) at the resolved Go bin path.
	@set -uo pipefail; \
	if ! mkdir -p "$(EXACTMAC_BUILD_LOG_DIR)" "$(EXACTMAC_MCP_BIN_DIR)"; then printf '%s\n' 'ERROR: failed to create build log or MCP binary directory.' >&2; exit 1; fi; \
	printf '%s\n' '=== Building exactmac ==='; \
	if ! cd "$(PROJECT_ROOT)"; then printf '%s\n' 'ERROR: project root is unavailable.' >&2; exit 1; fi; \
	if ! GOBIN="$(EXACTMAC_MCP_BIN_DIR)" go install ./cmd/exactmac 2>&1 | tee "$(EXACTMAC_MCP_BUILD_LOG)" | tail -n 30; then printf '%s\n' 'ERROR: exactmac build failed.' >&2; exit 1; fi; \
	test -x "$(EXACTMAC_MCP_BIN)" || { printf 'ERROR: MCP binary missing: %s\n' "$(EXACTMAC_MCP_BIN)" >&2; exit 1; }; \
	printf 'MCP binary: %s\n' "$(EXACTMAC_MCP_BIN)"

.PHONY: exactmac.build
exactmac.build: ## Build the Swift server, then the Go MCP proxy.
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.build-server
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.build-mcp
	@printf '%s\n' 'Build complete.'

# =============================================================================
# Bundle, sign, and registration
# =============================================================================

##@ [ExactMac] Bundle + Sign

.PHONY: exactmac.bundle
exactmac.bundle: ## Create a clean .app and include all SwiftPM resource bundles.
	@set -u; \
	validate_xml_value() { value="$$1"; name="$$2"; case "$$value" in *'<'*|*'>'*|*'&'*|*'"'*) printf 'ERROR: %s contains XML-significant characters.\\n' "$$name" >&2; exit 1;; esac; }; \
	validate_xml_value "$$EXACTMAC_APP_NAME" EXACTMAC_APP_NAME; \
	validate_xml_value "$$EXACTMAC_BUNDLE_ID" EXACTMAC_BUNDLE_ID; \
	validate_xml_value "$$EXACTMAC_VERSION" EXACTMAC_VERSION; \
	validate_xml_value "$$EXACTMAC_BUILD_VERSION" EXACTMAC_BUILD_VERSION; \
	validate_xml_value "$$EXACTMAC_MIN_MACOS" EXACTMAC_MIN_MACOS; \
	validate_xml_value "$$EXACTMAC_APP_EXECUTABLE" EXACTMAC_APP_EXECUTABLE; \
	if launchctl print "$(EXACTMAC_SERVICE_TARGET)" >/dev/null 2>&1; then \
		printf '%s\n' "ERROR: service is loaded; run 'gmake exactmac.stop' before replacing the app." >&2; \
		exit 1; \
	fi; \
	if [ ! -x "$(EXACTMAC_SERVER_BIN)" ]; then \
		printf 'ERROR: server binary not found: %s\n' "$(EXACTMAC_SERVER_BIN)" >&2; \
		printf '%s\n' "Run 'gmake exactmac.build-server' first." >&2; \
		exit 1; \
	fi; \
	if [ ! -d "$(EXACTMAC_REQUIRED_RESOURCE_BUNDLE)" ]; then \
		printf 'ERROR: required SwiftPM resource bundle not found: %s\n' "$(EXACTMAC_REQUIRED_RESOURCE_BUNDLE)" >&2; \
		exit 1; \
	fi; \
	printf '%s\n' '=== Creating staged application bundle ==='; \
	if ! rm -rf "$(EXACTMAC_STAGING_DIR)"; then printf '%s\n' 'ERROR: failed to clear bundle staging directory.' >&2; exit 1; fi; \
	if ! mkdir -p "$(EXACTMAC_STAGING_DIR)/Contents/MacOS" "$(EXACTMAC_STAGING_DIR)/Contents/Resources"; then printf '%s\n' 'ERROR: failed to create bundle staging directories.' >&2; exit 1; fi; \
	if ! install -m 0755 "$(EXACTMAC_SERVER_BIN)" "$(EXACTMAC_STAGING_DIR)/Contents/MacOS/$(EXACTMAC_APP_NAME)"; then printf '%s\n' 'ERROR: failed to install server executable into bundle.' >&2; exit 1; fi; \
	if ! printf '%s\n' "$$EXACTMAC_INFO_PLIST_E" > "$(EXACTMAC_STAGING_DIR)/Contents/Info.plist"; then printf '%s\n' 'ERROR: failed to write bundle Info.plist.' >&2; exit 1; fi; \
	resource_count=0; \
	for resource_bundle in "$(EXACTMAC_SERVER_BUILD_DIR)"/*.bundle; do \
		[ -d "$$resource_bundle" ] || continue; \
		resource_name=$$(basename "$$resource_bundle"); \
		if ! ditto "$$resource_bundle" "$(EXACTMAC_STAGING_DIR)/Contents/Resources/$$resource_name"; then printf 'ERROR: failed to copy resource bundle: %s\n' "$$resource_bundle" >&2; exit 1; fi; \
		resource_count=$$((resource_count + 1)); \
	done; \
	if [ "$$resource_count" -eq 0 ]; then \
		printf '%s\n' 'ERROR: no SwiftPM .bundle resources were copied.' >&2; \
		exit 1; \
	fi; \
	if ! plutil -lint "$(EXACTMAC_STAGING_DIR)/Contents/Info.plist"; then printf '%s\n' 'ERROR: generated Info.plist is invalid.' >&2; exit 1; fi; \
	if [ ! -d "$(EXACTMAC_STAGING_DIR)/Contents/Resources/$(EXACTMAC_RESOURCE_BUNDLE_NAME)" ]; then printf 'ERROR: required resource bundle missing: %s\n' "$(EXACTMAC_RESOURCE_BUNDLE_NAME)" >&2; exit 1; fi; \
	if ! rm -rf "$(EXACTMAC_APP_DIR)"; then printf '%s\n' 'ERROR: failed to replace installed app directory.' >&2; exit 1; fi; \
	if ! mkdir -p "$(dir $(EXACTMAC_APP_DIR))"; then printf '%s\n' 'ERROR: failed to create app parent directory.' >&2; exit 1; fi; \
	if ! mv "$(EXACTMAC_STAGING_DIR)" "$(EXACTMAC_APP_DIR)"; then printf '%s\n' 'ERROR: failed to install staged app bundle.' >&2; exit 1; fi; \
	printf 'Bundle created: %s (%s SwiftPM resource bundle(s))\n' "$(EXACTMAC_APP_DIR)" "$$resource_count"

.PHONY: exactmac.sign
exactmac.sign: private SHELL := /bin/bash
exactmac.sign: ## Sign the existing .app, then perform strict recursive verification.
	@set -uo pipefail; \
	if [ ! -x "$(EXACTMAC_APP_EXECUTABLE)" ]; then \
		printf '%s\n' "ERROR: app bundle is missing; run 'gmake exactmac.bundle' first." >&2; \
		exit 1; \
	fi; \
	if launchctl print "$(EXACTMAC_SERVICE_TARGET)" >/dev/null 2>&1; then \
		printf '%s\n' "ERROR: service is loaded; run 'gmake exactmac.stop' before signing." >&2; \
		exit 1; \
	fi; \
	printf '%s\n' '=== Clearing extended attributes from the generated app ==='; \
	if ! chmod -R u+w "$(EXACTMAC_APP_DIR)"; then printf '%s\n' 'ERROR: failed to make app writable for signing.' >&2; exit 1; fi; \
	if ! xattr -cr "$(EXACTMAC_APP_DIR)"; then printf '%s\n' 'ERROR: failed to clear app extended attributes.' >&2; exit 1; fi; \
	printf '=== Signing with identity: %s ===\n' "$(EXACTMAC_SIGN_IDENTITY)"; \
	if ! codesign --force --sign "$(EXACTMAC_SIGN_IDENTITY)" "$(EXACTMAC_APP_DIR)"; then printf '%s\n' 'ERROR: codesign failed.' >&2; exit 1; fi; \
	printf '%s\n' '=== Verifying signature (deep + strict) ==='; \
	if ! codesign --verify --deep --strict --verbose=4 "$(EXACTMAC_APP_DIR)"; then printf '%s\n' 'ERROR: codesign verification failed.' >&2; exit 1; fi; \
	codesign -d --verbose=4 "$(EXACTMAC_APP_DIR)" 2>&1 | grep -E '^(Executable|Identifier|Format|CodeDirectory|Signature|TeamIdentifier)=' || { printf '%s\n' 'ERROR: signed app metadata could not be read.' >&2; exit 1; }

.PHONY: exactmac.register
exactmac.register: ## Register the existing signed .app with LaunchServices.
	@set -u; \
	if [ ! -d "$(EXACTMAC_APP_DIR)" ]; then \
		printf '%s\n' "ERROR: app bundle is missing; run bundle and sign first." >&2; \
		exit 1; \
	fi; \
	if ! codesign --verify --deep --strict "$(EXACTMAC_APP_DIR)"; then printf '%s\n' 'ERROR: app signature verification failed.' >&2; exit 1; fi; \
	if ! "$(EXACTMAC_LSREGISTER)" -f "$(EXACTMAC_APP_DIR)"; then printf '%s\n' 'ERROR: LaunchServices registration failed.' >&2; exit 1; fi; \
	printf 'Registered %s (%s) with LaunchServices.\n' "$(EXACTMAC_APP_DIR)" "$(EXACTMAC_BUNDLE_ID)"

# =============================================================================
# LaunchAgent
# =============================================================================

##@ [ExactMac] LaunchAgent

.PHONY: exactmac.launchd
exactmac.launchd: ## Write, bootstrap, and wait for the per-user LaunchAgent.
	@set -u; \
	validate_xml_value() { value="$$1"; name="$$2"; case "$$value" in *'<'*|*'>'*|*'&'*|*'"'*) printf 'ERROR: %s contains XML-significant characters.\\n' "$$name" >&2; exit 1;; esac; }; \
	validate_xml_value "$$EXACTMAC_BUNDLE_ID" EXACTMAC_BUNDLE_ID; \
	validate_xml_value "$$EXACTMAC_APP_EXECUTABLE" EXACTMAC_APP_EXECUTABLE; \
	validate_xml_value "$$EXACTMAC_SOCKET" EXACTMAC_SOCKET; \
	validate_xml_value "$$EXACTMAC_STDOUT_LOG" EXACTMAC_STDOUT_LOG; \
	validate_xml_value "$$EXACTMAC_STDERR_LOG" EXACTMAC_STDERR_LOG; \
	if [ ! -x "$(EXACTMAC_APP_EXECUTABLE)" ]; then \
		printf '%s\n' 'ERROR: installed app executable is missing.' >&2; \
		exit 1; \
	fi; \
	if ! codesign --verify --deep --strict "$(EXACTMAC_APP_DIR)"; then printf '%s\n' 'ERROR: app signature verification failed.' >&2; exit 1; fi; \
	if ! mkdir -p "$(dir $(EXACTMAC_PLIST))" "$(dir $(EXACTMAC_SOCKET))" "$(dir $(EXACTMAC_CONSOLE_SOCKET))" "$(dir $(EXACTMAC_STDOUT_LOG))" "$(dir $(EXACTMAC_STDERR_LOG))"; then printf '%s\n' 'ERROR: failed to create LaunchAgent, socket, or log parent directories.' >&2; exit 1; fi; \
	plist_tmp=$$(mktemp "$(EXACTMAC_PLIST).tmp.XXXXXX") || { printf '%s\n' 'ERROR: failed to create temporary LaunchAgent plist.' >&2; exit 1; }; \
	cleanup_plist_tmp() { rm -f "$$plist_tmp"; }; \
	trap cleanup_plist_tmp EXIT INT TERM; \
	if ! printf '%s\n' "$$EXACTMAC_LAUNCHD_PLIST_E" > "$$plist_tmp"; then printf '%s\n' 'ERROR: failed to write LaunchAgent plist.' >&2; exit 1; fi; \
	if ! plutil -lint "$$plist_tmp"; then printf '%s\n' 'ERROR: generated LaunchAgent plist is invalid.' >&2; exit 1; fi; \
	if ! chmod 600 "$$plist_tmp"; then printf '%s\n' 'ERROR: failed to secure temporary LaunchAgent plist.' >&2; exit 1; fi; \
	service_absent() { output=$$(launchctl print "$(EXACTMAC_SERVICE_TARGET)" 2>&1); status=$$?; [ "$$status" -ne 0 ] && printf '%s\n' "$$output" | grep -Fq 'Could not find service'; }; \
	if ! launchctl bootout "$(EXACTMAC_SERVICE_TARGET)" >/dev/null 2>&1; then \
		if ! service_absent; then printf '%s\n' 'ERROR: could not confirm LaunchAgent bootout; refusing replacement.' >&2; exit 1; fi; \
	fi; \
	attempt=0; \
	while ! service_absent && [ "$$attempt" -lt 10 ]; do sleep 1; attempt=$$((attempt + 1)); done; \
	if ! service_absent; then \
		printf '%s\n' 'ERROR: LaunchAgent remained loaded or could not be queried; refusing replacement.' >&2; \
		exit 1; \
	fi; \
	if ! mv "$$plist_tmp" "$(EXACTMAC_PLIST)"; then printf '%s\n' 'ERROR: failed to install LaunchAgent plist.' >&2; exit 1; fi; \
	if ! launchctl enable "$(EXACTMAC_SERVICE_TARGET)"; then printf '%s\n' 'ERROR: failed to enable LaunchAgent.' >&2; exit 1; fi; \
	if ! launchctl bootstrap "$(EXACTMAC_LAUNCH_DOMAIN)" "$(EXACTMAC_PLIST)"; then printf '%s\n' 'ERROR: failed to bootstrap LaunchAgent.' >&2; exit 1; fi
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.wait

.PHONY: exactmac.wait
exactmac.wait:
	@socket_endpoint_ready() { \
		[ -S "$(EXACTMAC_SOCKET)" ] && [ ! -L "$(EXACTMAC_SOCKET)" ] || return 1; \
		socket_owner=$$(stat -f '%u' "$(EXACTMAC_SOCKET)" 2>/dev/null || true); \
		socket_mode=$$(stat -f '%Sp' "$(EXACTMAC_SOCKET)" 2>/dev/null || true); \
		[ "$$socket_owner" = "$(EXACTMAC_UID)" ] && [ "$$socket_mode" = 'srw-------' ]; \
	}; \
	attempt=0; \
	while [ "$$attempt" -lt "$(EXACTMAC_WAIT_ATTEMPTS)" ]; do \
		if launchctl print "$(EXACTMAC_SERVICE_TARGET)" 2>/dev/null | grep -q 'state = running' \
			&& socket_endpoint_ready; then \
			printf 'Service ready: %s\n' "$(EXACTMAC_SERVICE_TARGET)"; \
			ls -l "$(EXACTMAC_SOCKET)"; \
			exit 0; \
		fi; \
		attempt=$$((attempt + 1)); \
		sleep "$(EXACTMAC_WAIT_INTERVAL)"; \
	done; \
	printf 'ERROR: service/socket not ready after %s attempt(s).\n' "$(EXACTMAC_WAIT_ATTEMPTS)" >&2; \
	launchctl print "$(EXACTMAC_SERVICE_TARGET)" 2>&1 | sed -n '1,80p' >&2 || true; \
	tail -n 40 "$(EXACTMAC_STDERR_LOG)" 2>/dev/null >&2 || true; \
	exit 1

# =============================================================================
# Full install and verification
# =============================================================================

##@ [ExactMac] Install + Verify

.PHONY: exactmac.install
exactmac.install: ## Doctor + build + stop + bundle + sign + register + launch + verify.
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.doctor
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.build
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.stop
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.bundle
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.sign
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.register
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.launchd
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.verify
	@printf '\n%s\n' '============================================================'; \
	printf '%s\n' '  EXACTMAC INSTALL COMPLETE'; \
	printf '%s\n' '============================================================'; \
	printf '  App:       %s\n' "$(EXACTMAC_APP_DIR)"; \
	printf '  MCP:       %s\n' "$(EXACTMAC_MCP_BIN)"; \
	printf '  Socket:    %s\n' "$(EXACTMAC_SOCKET)"; \
	printf '  Service:   %s\n' "$(EXACTMAC_SERVICE_TARGET)"; \
	printf '  Signing:   %s\n' "$(EXACTMAC_SIGN_IDENTITY)"; \
	printf '\n%s\n' '  Grant Accessibility and Screen & System Audio Recording'; \
	printf '%s\n' '  in System Settings > Privacy & Security, then run:'; \
	printf '%s\n' '    gmake exactmac.restart'; \
	if [ "$(EXACTMAC_SIGN_IDENTITY)" = '-' ]; then \
		printf '\n%s\n' '  NOTE: ad-hoc signing is convenient but TCC grants may be lost'; \
		printf '%s\n' '        after a rebuild. Use an Apple Development identity for'; \
		printf '%s\n' '        stable grants across builds.'; \
	fi; \
	printf '%s\n' '============================================================'

.PHONY: exactmac.verify
exactmac.verify: ## Fail unless bundle, resources, signature, service, socket, and MCP are valid.
	@failed=0; \
	pass() { printf '  PASS  %s\n' "$$1"; }; \
	fail() { printf '  FAIL  %s\n' "$$1" >&2; failed=1; }; \
	printf '%s\n' '=== Verifying ExactMac deployment ==='; \
	if [ -d "$(EXACTMAC_APP_DIR)" ]; then pass 'application bundle exists'; else fail 'application bundle is missing'; fi; \
	if [ -x "$(EXACTMAC_APP_EXECUTABLE)" ]; then pass 'server executable exists and is executable'; else fail 'server executable is missing or not executable'; fi; \
	if plutil -lint "$(EXACTMAC_APP_DIR)/Contents/Info.plist" >/dev/null 2>&1; then pass 'Info.plist is valid'; else fail 'Info.plist is invalid or missing'; fi; \
	bundle_id=$$(plutil -extract CFBundleIdentifier raw -o - "$(EXACTMAC_APP_DIR)/Contents/Info.plist" 2>/dev/null || true); \
	if [ "$$bundle_id" = "$(EXACTMAC_BUNDLE_ID)" ]; then pass 'bundle identifier matches'; else fail "bundle identifier mismatch: $$bundle_id"; fi; \
	if [ -d "$(EXACTMAC_APP_DIR)/Contents/Resources/$(EXACTMAC_RESOURCE_BUNDLE_NAME)" ]; then pass 'SwiftPM resource bundle is installed in Contents/Resources'; else fail 'SwiftPM resource bundle is missing from Contents/Resources'; fi; \
		if [ -d "$(EXACTMAC_APP_DIR)/Contents/Resources/$(EXACTMAC_RESOURCE_BUNDLE_NAME)" ] && find "$(EXACTMAC_APP_DIR)/Contents/Resources/$(EXACTMAC_RESOURCE_BUNDLE_NAME)" -type f -name "*.pb" -print -quit 2>/dev/null | grep -q .; then pass 'resource bundle accessible in Contents/Resources'; else fail 'resource bundle not accessible'; fi; \
	if find "$(EXACTMAC_APP_DIR)/Contents/Resources/$(EXACTMAC_RESOURCE_BUNDLE_NAME)" -type f -name '*.pb' -print -quit 2>/dev/null | grep -q .; then pass 'protobuf descriptor resources are present'; else fail 'protobuf descriptor resources are missing'; fi; \
	if codesign --verify --deep --strict "$(EXACTMAC_APP_DIR)" >/dev/null 2>&1; then pass 'code signature passes deep strict verification'; else fail 'code signature verification failed'; fi; \
	if plutil -lint "$(EXACTMAC_PLIST)" >/dev/null 2>&1; then pass 'LaunchAgent plist is valid'; else fail 'LaunchAgent plist is invalid or missing'; fi; \
	if launchctl print "$(EXACTMAC_SERVICE_TARGET)" >/dev/null 2>&1; then pass 'LaunchAgent is loaded in the GUI domain'; else fail 'LaunchAgent is not loaded'; fi; \
	if launchctl print "$(EXACTMAC_SERVICE_TARGET)" 2>/dev/null | grep -q 'state = running'; then pass 'LaunchAgent process is running'; else fail 'LaunchAgent is not in the running state'; fi; \
	if [ -S "$(EXACTMAC_SOCKET)" ] && [ ! -L "$(EXACTMAC_SOCKET)" ]; then pass 'Unix socket exists without symlink indirection'; else fail 'Unix socket is missing or is a symlink'; fi; \
	if [ -S "$(EXACTMAC_SOCKET)" ] && [ ! -L "$(EXACTMAC_SOCKET)" ]; then \
		socket_owner=$$(stat -f '%u' "$(EXACTMAC_SOCKET)" 2>/dev/null || true); \
		socket_mode=$$(stat -f '%Sp' "$(EXACTMAC_SOCKET)" 2>/dev/null || true); \
		if [ "$$socket_owner" = "$(EXACTMAC_UID)" ]; then pass 'Unix socket owner matches current user'; else fail "Unix socket owner mismatch: $$socket_owner"; fi; \
		if [ "$$socket_mode" = 'srw-------' ]; then pass 'Unix socket mode is 0600'; else fail "Unix socket mode is not 0600: $$socket_mode"; fi; \
	fi; \
	if [ -x "$(EXACTMAC_MCP_BIN)" ]; then pass 'exactmac binary exists and is executable'; else fail "exactmac is missing: $(EXACTMAC_MCP_BIN)"; fi; \
	printf '%s\n' '--- Signature identity ---'; \
	codesign -d --verbose=4 "$(EXACTMAC_APP_DIR)" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)=' || true; \
	printf '%s\n' '--- Embedded entitlements ---'; \
	if ! codesign -d --entitlements :- "$(EXACTMAC_APP_DIR)" 2>/dev/null; then printf '%s\n' '  (none)'; fi; \
	if [ "$$failed" -ne 0 ]; then printf '%s\n' 'Deployment verification FAILED.' >&2; exit 1; fi; \
	printf '%s\n' 'Deployment verification passed.'

# =============================================================================
# Lifecycle and diagnostics
# =============================================================================

##@ [ExactMac] Lifecycle

.PHONY: exactmac.status
exactmac.status: ## Show exact LaunchAgent, process, socket, signature, and MCP status.
	@printf '%s\n' '=== LaunchAgent ==='; \
	launchctl print "$(EXACTMAC_SERVICE_TARGET)" 2>/dev/null | sed -n '1,45p' || printf '%s\n' '  not loaded'; \
	printf '%s\n' '=== Socket ==='; \
	ls -l "$(EXACTMAC_SOCKET)" 2>/dev/null || printf '%s\n' '  not found'; \
	printf '%s\n' '=== App signature ==='; \
	codesign -d --verbose=4 "$(EXACTMAC_APP_DIR)" 2>&1 | grep -E '^(Executable|Identifier|Format|Signature|TeamIdentifier)=' || printf '%s\n' '  not signed'; \
	printf '%s\n' '=== MCP binary ==='; \
	if [ -x "$(EXACTMAC_MCP_BIN)" ]; then ls -l "$(EXACTMAC_MCP_BIN)"; else printf '  not found: %s\n' "$(EXACTMAC_MCP_BIN)"; fi

.PHONY: exactmac.start
exactmac.start: ## Start the service without rebuilding or signing.
	@set -u; \
	if [ ! -f "$(EXACTMAC_PLIST)" ]; then printf '%s\n' "ERROR: missing $(EXACTMAC_PLIST)" >&2; exit 1; fi; \
	if launchctl print "$(EXACTMAC_SERVICE_TARGET)" >/dev/null 2>&1; then \
		if ! launchctl kickstart "$(EXACTMAC_SERVICE_TARGET)"; then printf '%s\n' 'ERROR: failed to kickstart LaunchAgent.' >&2; exit 1; fi; \
	else \
		if ! launchctl enable "$(EXACTMAC_SERVICE_TARGET)"; then printf '%s\n' 'ERROR: failed to enable LaunchAgent.' >&2; exit 1; fi; \
		if ! launchctl bootstrap "$(EXACTMAC_LAUNCH_DOMAIN)" "$(EXACTMAC_PLIST)"; then printf '%s\n' 'ERROR: failed to bootstrap LaunchAgent.' >&2; exit 1; fi; \
	fi
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.wait

.PHONY: exactmac.restart
exactmac.restart: ## Restart the service without rebuilding or re-signing.
	@set -u; \
	if [ ! -f "$(EXACTMAC_PLIST)" ]; then printf '%s\n' "ERROR: missing $(EXACTMAC_PLIST)" >&2; exit 1; fi; \
	if launchctl print "$(EXACTMAC_SERVICE_TARGET)" >/dev/null 2>&1; then \
		if ! launchctl kickstart -k "$(EXACTMAC_SERVICE_TARGET)"; then printf '%s\n' 'ERROR: failed to restart LaunchAgent.' >&2; exit 1; fi; \
	else \
		if ! launchctl enable "$(EXACTMAC_SERVICE_TARGET)"; then printf '%s\n' 'ERROR: failed to enable LaunchAgent.' >&2; exit 1; fi; \
		if ! launchctl bootstrap "$(EXACTMAC_LAUNCH_DOMAIN)" "$(EXACTMAC_PLIST)"; then printf '%s\n' 'ERROR: failed to bootstrap LaunchAgent.' >&2; exit 1; fi; \
	fi
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.wait

.PHONY: exactmac.stop
exactmac.stop: ## Stop and unload the service; preserve app, plist, MCP, and TCC grants.
	@set -u; \
	printf '%s\n' 'Stopping ExactMacServer LaunchAgent...'; \
	service_absent() { output=$$(launchctl print "$(EXACTMAC_SERVICE_TARGET)" 2>&1); status=$$?; [ "$$status" -ne 0 ] && printf '%s\n' "$$output" | grep -Eq 'Could not find service|No such process|service does not exist'; }; \
	if ! launchctl bootout "$(EXACTMAC_SERVICE_TARGET)" >/dev/null 2>&1; then \
		if ! service_absent; then printf '%s\n' 'ERROR: could not confirm LaunchAgent bootout; refusing success.' >&2; exit 1; fi; \
	fi; \
	attempt=0; \
	while ! service_absent && [ "$$attempt" -lt 10 ]; do sleep 1; attempt=$$((attempt + 1)); done; \
	if ! service_absent; then \
		printf '%s\n' 'ERROR: LaunchAgent remained loaded or could not be queried; service was not confirmed stopped.' >&2; \
		exit 1; \
	fi; \
	printf '%s\n' 'Service stopped.'

.PHONY: exactmac.tcc-reset
exactmac.tcc-reset: ## Reset Accessibility and ScreenCapture TCC records for this bundle ID.
	@printf 'Resetting TCC records for %s...\n' "$(EXACTMAC_BUNDLE_ID)"; \
	for tcc_service in Accessibility ScreenCapture; do \
		if tccutil reset "$$tcc_service" "$(EXACTMAC_BUNDLE_ID)"; then \
			printf '  reset %s\n' "$$tcc_service"; \
		else \
			printf '  warning: could not reset %s (there may be no matching record)\n' "$$tcc_service" >&2; \
		fi; \
	done; \
	printf '%s\n' 'Re-grant permissions in System Settings, then run gmake exactmac.restart.'

.PHONY: exactmac.logs
exactmac.logs: ## Show recent stdout, stderr, and unified-log entries.
	@printf '%s\n' '=== stdout (last 40 lines) ==='; \
	tail -n 40 "$(EXACTMAC_STDOUT_LOG)" 2>/dev/null || printf '%s\n' '(empty)'; \
	printf '%s\n' '=== stderr (last 40 lines) ==='; \
	tail -n 40 "$(EXACTMAC_STDERR_LOG)" 2>/dev/null || printf '%s\n' '(empty)'; \
	printf '%s\n' '=== unified log (last 5 minutes) ==='; \
	log show --last 5m --style compact --predicate 'process == "ExactMacServer"' 2>/dev/null | tail -n 80 || printf '%s\n' '(unavailable)'

.PHONY: exactmac.uninstall
exactmac.uninstall: ## Remove app, LaunchAgent, plist, logs, MCP binary, and TCC records; preserve the configured socket pathname.
	@printf '%s\n' '=== Uninstalling ExactMacServer ==='; \
	service_absent() { output=$$(launchctl print "$(EXACTMAC_SERVICE_TARGET)" 2>&1); status=$$?; [ "$$status" -ne 0 ] && printf '%s\n' "$$output" | grep -Eq 'Could not find service|No such process|service does not exist'; }; \
	if ! launchctl bootout "$(EXACTMAC_SERVICE_TARGET)" >/dev/null 2>&1; then \
		if ! service_absent; then printf '%s\n' 'ERROR: could not confirm LaunchAgent bootout; refusing uninstall.' >&2; exit 1; fi; \
	fi; \
	attempt=0; \
	while ! service_absent && [ "$$attempt" -lt 10 ]; do sleep 1; attempt=$$((attempt + 1)); done; \
	if ! service_absent; then \
		printf '%s\n' 'ERROR: LaunchAgent remained loaded or could not be queried; refusing uninstall.' >&2; \
		exit 1; \
	fi; \

	for tcc_service in Accessibility ScreenCapture; do \
		tccutil reset "$$tcc_service" "$(EXACTMAC_BUNDLE_ID)" >/dev/null 2>&1 || true; \
	done; \
	if [ -d "$(EXACTMAC_APP_DIR)" ]; then "$(EXACTMAC_LSREGISTER)" -u "$(EXACTMAC_APP_DIR)" >/dev/null 2>&1 || true; fi; \
	rm -rf "$(EXACTMAC_APP_DIR)" "$(EXACTMAC_STAGING_DIR)"; \
	rm -f "$(EXACTMAC_PLIST)"; \
	rm -f "$(EXACTMAC_STDOUT_LOG)" "$(EXACTMAC_STDERR_LOG)"; \
	rm -f "$(EXACTMAC_MCP_BIN)"; \
	printf '%s\n' 'Uninstall complete.'

# Convenience target for deterministic TextEdit automation testing.
.PHONY: exactmac-open-textedit-doc
exactmac-open-textedit-doc: ## Open an empty TextEdit document at a stable path.
	@mkdir -p "$(PROJECT_ROOT)"; \
	: > "$(PROJECT_ROOT)/tmp_hello.txt"; \
	open -a TextEdit "$(PROJECT_ROOT)/tmp_hello.txt"
