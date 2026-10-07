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
# THE PRODUCT NAME, NOT THE TARGET NAME. `ExactMacServer` is the SwiftPM library target and
# builds to `libExactMacServer.a`; the runnable product is `exactmac-server`, and SwiftPM
# names a binary after the product rather than the target. The bundle's executable is
# therefore named for the product while the resource bundle beside it is still named for the
# target, because the bundle name comes from the target.
EXACTMAC_SERVER_PRODUCT         ?= exactmac-server
EXACTMAC_SERVER_BIN              ?= $(EXACTMAC_SERVER_BUILD_DIR)/$(EXACTMAC_SERVER_PRODUCT)
EXACTMAC_RESOURCE_BUNDLE_NAME    ?= ExactMacServer_ExactMacServer.bundle
EXACTMAC_REQUIRED_RESOURCE_BUNDLE := $(EXACTMAC_SERVER_BUILD_DIR)/$(EXACTMAC_RESOURCE_BUNDLE_NAME)

EXACTMAC_PLIST          ?= $(HOME)/Library/LaunchAgents/$(EXACTMAC_BUNDLE_ID).plist
EXACTMAC_SOCKET         ?= $(HOME)/Library/Caches/exactmac.sock
# The consent channel, in the same owner-only state directory as the grant store and the audit
# log. It is set HERE and not defaulted in the server, because an absent channel is a
# deliberate fail-closed configuration: a server without one refuses every consent-requiring
# capability, and a server that went looking for a channel nobody configured would bind a
# socket it had no reason to own.
# The state directory, WHERE THE SERVER KEEPS ITS OWN STATE, and it is spelled out rather
# than derived.
#
# IT USED TO BE `$(dir $(EXACTMAC_CONSOLE_SOCKET))`, on the reasoning that deriving it kept
# the two in agreement. The console socket is gone — the app is one process and presents
# consent itself — so the derivation was a live coupling to a retired path: renaming the
# console socket, or a person "tidying up" a pathname they thought was dead, would have
# silently moved the GRANT STORE and the audit log with it. A state directory that moves
# because a different variable changed is a state directory that can be lost.
#
# The trailing slash is deliberate and load-bearing: it is used as a path PREFIX below
# (`$(EXACTMAC_STATE_DIR)grant-store`), which is what `$(dir ...)` used to provide, and
# dropping it would concatenate `~joeyc.exactmac`.
EXACTMAC_STATE_DIR       ?= $(HOME)/.exactmac/
# The retired console socket, kept only so a stale deployment's environment can still be
# READ and diagnosed. NOTHING creates it, nothing connects to it, and it is deliberately
# NOT handed to any generated plist: the server still parses it into a config field that no
# production code reads, so passing it would be a deployment asserting a channel that the
# architecture no longer has. See `exactmac.retire-launchagents`.
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
EXACTMAC_CONSOLE_SERVICE_TARGET := $(EXACTMAC_LAUNCH_DOMAIN)/$(EXACTMAC_CONSOLE_BUNDLE_ID)
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
# The console's own product paths. THE BUNDLE IDENTITY IS NO LONGER A SECURITY BOUNDARY: the
# comment this replaced said the console keeps a separate identifier from the server's
# "on purpose: the two are separately signed, separately granted TCC access, and separately
# launched, and a shared identifier would make one process's permissions the other's". That
# was true when there were two processes and is false now that the app hosts the server, so
# the two ids have to merge — which costs the operator one re-grant of Accessibility and
# Screen Recording, exactly once, at the migration. That cost is unavoidable whichever id
# survives, because the server's own bundle is what disappears, and it is recorded in
# blueprint.json gf-4 rather than argued about again.
EXACTMAC_CONSOLE_APP_NAME         ?= ExactMacConsole
EXACTMAC_CONSOLE_BUNDLE_ID        ?= com.exactmac.console
EXACTMAC_CONSOLE_VERSION          ?= $(EXACTMAC_VERSION)
EXACTMAC_CONSOLE_BUILD_VERSION    ?= $(EXACTMAC_BUILD_VERSION)
# macOS 15, matching Console/Package.swift's own deployment target. Declaring anything
# lower would advertise a platform the binary does not build for.
EXACTMAC_CONSOLE_MIN_MACOS        ?= 15.0
EXACTMAC_CONSOLE_APP_DIR          ?= $(HOME)/Applications/$(EXACTMAC_CONSOLE_APP_NAME).app
EXACTMAC_CONSOLE_APP_EXECUTABLE  := $(EXACTMAC_CONSOLE_APP_DIR)/Contents/MacOS/$(EXACTMAC_CONSOLE_APP_NAME)
EXACTMAC_CONSOLE_STAGING_DIR      := $(EXACTMAC_CONSOLE_APP_DIR).staging
EXACTMAC_CONSOLE_BUILD_DIR       ?= $(PROJECT_ROOT)/Console/.build/release
EXACTMAC_CONSOLE_BIN             := $(EXACTMAC_CONSOLE_BUILD_DIR)/$(EXACTMAC_CONSOLE_APP_NAME)
EXACTMAC_CONSOLE_RESOURCE_BUNDLE_NAME := $(EXACTMAC_CONSOLE_APP_NAME)_$(EXACTMAC_CONSOLE_APP_NAME).bundle
EXACTMAC_CONSOLE_REQUIRED_RESOURCE_BUNDLE := $(EXACTMAC_CONSOLE_BUILD_DIR)/$(EXACTMAC_CONSOLE_RESOURCE_BUNDLE_NAME)
EXACTMAC_CONSOLE_PLIST           ?= $(HOME)/Library/LaunchAgents/$(EXACTMAC_CONSOLE_BUNDLE_ID).plist
EXACTMAC_CONSOLE_BUILD_LOG        ?= $(EXACTMAC_BUILD_LOG_DIR)/exactmac-console.log
# Runtime logs, in the operator's own log directory rather than the repository's build log
# directory: a build artefact directory is not somewhere a service should keep state, and
# `gmake clean` would take the operator's diagnostics with it.
EXACTMAC_CONSOLE_STDOUT_LOG       ?= $(HOME)/Library/Logs/exactmac-console.log
EXACTMAC_CONSOLE_STDERR_LOG       ?= $(HOME)/Library/Logs/exactmac-console.error.log

EXACTMAC_MCP_BIN ?= $(EXACTMAC_GO_BIN_DIR)/exactmac
EXACTMAC_MCP_BIN_DIR := $(patsubst %/,%,$(dir $(EXACTMAC_MCP_BIN)))
EXACTMAC_CONSOLE_SERVICE_TARGET := $(EXACTMAC_LAUNCH_DOMAIN)/$(EXACTMAC_CONSOLE_BUNDLE_ID)

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

# The console's bundle. LSUIElement for the same reason as the server's and for a stronger
# one: the operator's way in is the menu bar, so a Dock icon would be a second, worse door.
define EXACTMAC_CONSOLE_INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$(EXACTMAC_CONSOLE_APP_NAME)</string>
    <key>CFBundleExecutable</key>
    <string>$(EXACTMAC_CONSOLE_APP_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(EXACTMAC_CONSOLE_BUNDLE_ID)</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(EXACTMAC_CONSOLE_APP_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(EXACTMAC_CONSOLE_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(EXACTMAC_CONSOLE_BUILD_VERSION)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(EXACTMAC_CONSOLE_MIN_MACOS)</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
endef

# THE CONSOLE'S LAUNCHAGENT TEMPLATE IS GONE, and its removal is the point rather than a
# tidy-up. The template is a working recipe for the two-process architecture: a menu-bar
# app, supervised by launchd, talking to a separately-supervised server over a console
# socket. All three halves of that are retired — the app is one process, it registers
# itself for start-at-login through `ServiceManagement.SMAppService.mainApp`, and there is
# no console socket. A template that is merely unreferenced is worse than no template,
# because it is copy-pasteable: the next person who reaches for "how do I install this"
# would get a plist that resurrects the design this work removed, and nothing in it says so.

export EXACTMAC_CONSOLE_INFO_PLIST_E := $(EXACTMAC_CONSOLE_INFO_PLIST)
export EXACTMAC_CONSOLE_APP_NAME EXACTMAC_CONSOLE_BUNDLE_ID EXACTMAC_CONSOLE_VERSION
export EXACTMAC_CONSOLE_BUILD_VERSION EXACTMAC_CONSOLE_MIN_MACOS EXACTMAC_CONSOLE_APP_EXECUTABLE
export EXACTMAC_CONSOLE_BUILD_LOG EXACTMAC_CONSOLE_STDOUT_LOG EXACTMAC_CONSOLE_STDERR_LOG

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
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_BUILD_LOG))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_BIN))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_BUILD_DIR))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_PLIST))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_APP_EXECUTABLE))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_APP_DIR))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_MIN_MACOS))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_BUILD_VERSION))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_VERSION))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_BUNDLE_ID))
$(eval $(call EXACTMAC_VALIDATE_CONFIG,EXACTMAC_CONSOLE_APP_NAME))
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
$(eval $(call EXACTMAC_VALIDATE_VALUE,$(EXACTMAC_CONSOLE_STAGING_DIR),EXACTMAC_CONSOLE_STAGING_DIR))
$(eval $(call EXACTMAC_VALIDATE_VALUE,$(EXACTMAC_CONSOLE_REQUIRED_RESOURCE_BUNDLE),EXACTMAC_CONSOLE_REQUIRED_RESOURCE_BUNDLE))
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
	# THE PRODUCT, EXPLICITLY. A bare `swift build` builds every product including the
	# `ExactMacServer` library, which produces no runnable file, so the binary check below
	# would fail against a build that had in fact succeeded.
	# The product name reaches the shell as an exported variable rather than inline expansion.
	EXACTMAC_SERVER_PRODUCT="$(EXACTMAC_SERVER_PRODUCT)"; export EXACTMAC_SERVER_PRODUCT; \
	if ! swift build --configuration release --product "$$EXACTMAC_SERVER_PRODUCT" 2>&1 | tee "$(EXACTMAC_SERVER_BUILD_LOG)" | tail -n 40; then printf '%s\n' 'ERROR: Swift server build failed.' >&2; exit 1; fi; \
	test -x "$(EXACTMAC_SERVER_BIN)" || { printf 'ERROR: server binary missing: %s\n' "$(EXACTMAC_SERVER_BIN)" >&2; exit 1; }; \
	ln -sf "$$EXACTMAC_SERVER_PRODUCT" "$(EXACTMAC_SERVER_BUILD_DIR)/ExactMacServer"; \
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
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.check-mcp-host

.PHONY: exactmac.check-mcp-host
exactmac.check-mcp-host: ## Check running exactmac mcp processes against on-disk binary mtime to catch stale processes.
	@set -uo pipefail; \
	bin="$(EXACTMAC_MCP_BIN)"; \
	if [ ! -x "$$bin" ]; then printf 'ERROR: MCP binary missing: %s\n' "$$bin" >&2; exit 1; fi; \
	bin_mtime=$$(stat -f %m "$$bin"); \
	printf '=== MCP Process Attribution Check ===\n'; \
	printf 'On-disk binary: %s (mtime: %s)\n' "$$bin" "$$(date -r "$$bin_mtime")"; \
	stale_count=0; \
	pids=$$(pgrep -f "exactmac mcp" || true); \
	if [ -z "$$pids" ]; then \
		printf 'No running exactmac mcp processes found.\n'; \
	else \
		for pid in $$pids; do \
			lstart=$$(ps -o lstart= -p "$$pid" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]\{2,\}/ /g'); \
			if [ -n "$$lstart" ]; then \
				start=$$(date -j -f "%a %b %d %T %Y" "$$lstart" +%s 2>/dev/null || echo 0); \
				if [ "$$start" -lt "$$bin_mtime" ]; then \
					printf '  [STALE] PID %s started %s (predates binary)\n' "$$pid" "$$lstart"; \
					stale_count=$$((stale_count + 1)); \
				else \
					printf '  [FRESH] PID %s started %s (postdates binary)\n' "$$pid" "$$lstart"; \
				fi; \
			fi; \
		done; \
		if [ "$$stale_count" -gt 0 ]; then \
			printf '\nWARNING: %d stale exactmac mcp process(es) detected!\n' "$$stale_count"; \
			printf 'The MCP host (IDE / client) must be restarted or stale processes killed for the new binary to take effect.\n'; \
		else \
			printf 'All running exactmac mcp processes are fresh.\n'; \
		fi; \
	fi

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
	validate_xml_value "$$EXACTMAC_CONSOLE_SOCKET" EXACTMAC_CONSOLE_SOCKET; \
	validate_xml_value "$$EXACTMAC_STDOUT_LOG" EXACTMAC_STDOUT_LOG; \
	validate_xml_value "$$EXACTMAC_STDERR_LOG" EXACTMAC_STDERR_LOG; \
	if ! mkdir -p "$(EXACTMAC_STATE_DIR)"; then printf '%s\n' 'ERROR: failed to create the state directory.' >&2; exit 1; fi; \
	if ! chmod 700 "$(EXACTMAC_STATE_DIR)"; then printf '%s\n' 'ERROR: failed to restrict the state directory to 0700.' >&2; exit 1; fi; \
	if [ "$$(stat -f '%Lp' "$(EXACTMAC_STATE_DIR)")" != "700" ]; then printf '%s\n' 'ERROR: the state directory is not 0700; the server will refuse to start against it.' >&2; exit 1; fi; \
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
# A READY SERVER IS ONE THAT IS RUNNING *AND* IS SERVING THIS SOCKET, and the second
# half is not decoration. A node left at the pathname by a previous run satisfies every
# mode and ownership check, and a launchd job in its restart backoff briefly reports
# `state = running` between attempts, so a check that looked only at those two passed
# against a service that was crash-looping on a startup failure and reported the install
# as complete. The handshake is what distinguishes them: the server answers it, and a server
# that failed before it bound cannot.
#
# The socket path is passed to the probe IN rather than inherited, because the server learns
# it from the LaunchAgent's EnvironmentVariables and a shell that did not export it would
# probe nothing and report a healthy service as down.
#
# NO SHELL COMMENT MAY APPEAR INSIDE THIS RECIPE. A `#` line without a trailing backslash is
# a separate recipe line, so make runs it in a separate shell and the functions defined above
# it are gone by the time they are called; with one, `#` swallows the rest of the joined line,
# braces included. Both were tried and both fail loudly rather than quietly.
exactmac.wait:
	@socket_endpoint_ready() { \
		[ -S "$(EXACTMAC_SOCKET)" ] && [ ! -L "$(EXACTMAC_SOCKET)" ] || return 1; \
		socket_owner=$$(stat -f '%u' "$(EXACTMAC_SOCKET)" 2>/dev/null || true); \
		socket_mode=$$(stat -f '%Sp' "$(EXACTMAC_SOCKET)" 2>/dev/null || true); \
		[ "$$socket_owner" = "$(EXACTMAC_UID)" ] && [ "$$socket_mode" = 'srw-------' ]; \
	}; \
	answering() { \
		EXACTMAC_SERVER_SOCKET_PATH="$(EXACTMAC_SOCKET)" \
			"$(EXACTMAC_MCP_BIN)" health >/dev/null 2>&1; \
	}; \
	attempt=0; \
	while [ "$$attempt" -lt "$(EXACTMAC_WAIT_ATTEMPTS)" ]; do \
		if launchctl print "$(EXACTMAC_SERVICE_TARGET)" 2>/dev/null | grep -q 'state = running' \
			&& socket_endpoint_ready \
			&& answering; then \
			printf 'Service ready: %s\n' "$(EXACTMAC_SERVICE_TARGET)"; \
			ls -l "$(EXACTMAC_SOCKET)"; \
			exit 0; \
		fi; \
		attempt=$$((attempt + 1)); \
		sleep "$(EXACTMAC_WAIT_INTERVAL)"; \
	done; \
	printf 'ERROR: service/socket not ready after %s attempt(s).\n' "$(EXACTMAC_WAIT_ATTEMPTS)" >&2; \
	printf '%s\n' '--- the service state ---' >&2; \
	launchctl print "$(EXACTMAC_SERVICE_TARGET)" 2>&1 | sed -n '1,80p' >&2 || true; \
	printf '%s\n' '--- the unified log, where a startup failure is recorded ---' >&2; \
	log show --info --last 5m --style compact --predicate 'process == "$(EXACTMAC_SERVER_PRODUCT)"' 2>/dev/null \
		| grep -E 'Main' | tail -n 20 >&2 || true; \
	printf '%s\n' '--- stderr ---' >&2; \
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
exactmac.tcc-reset: ## Reset the Accessibility and ScreenCapture TCC records, for both the app and the retired server id.
	@# BOTH IDENTITIES, because the one-time migration means a machine can still hold a
	@# record for the old server bundle. Resetting only the new one leaves the stale record
	@# behind, and resetting only the old one would do nothing on a fresh install.
	@printf 'Resetting TCC records...\n'; \
	reset_one() { \
		if tccutil reset "$$1" "$$2"; then printf '  reset %s for %s\n' "$$1" "$$2"; \
		else printf '  warning: no %s record for %s (nothing to reset)\n' "$$1" "$$2" >&2; fi; \
	}; \
	for tcc_service in Accessibility ScreenCapture; do \
		reset_one "$$tcc_service" "$(EXACTMAC_CONSOLE_BUNDLE_ID)"; \
		reset_one "$$tcc_service" "$(EXACTMAC_BUNDLE_ID)"; \
	done; \
	printf '%s\n' ''; \
	printf '%s\n' 'Re-grant both in System Settings > Privacy & Security, then launch the app again.'

.PHONY: exactmac.logs
exactmac.logs: ## Show recent stdout, stderr, and unified-log entries.
	@printf '%s\n' '=== stdout (last 40 lines) ==='; \
	tail -n 40 "$(EXACTMAC_STDOUT_LOG)" 2>/dev/null || printf '%s\n' '(empty)'; \
	printf '%s\n' '=== stderr (last 40 lines) ==='; \
	tail -n 40 "$(EXACTMAC_STDERR_LOG)" 2>/dev/null || printf '%s\n' '(empty)'; \
	printf '%s\n' '=== unified log (last 5 minutes) ==='; \
	log show --last 5m --style compact --predicate 'process == "$(EXACTMAC_SERVER_PRODUCT)"' 2>/dev/null | tail -n 80 || printf '%s\n' '(unavailable)'

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

# =============================================================================
# ExactMacConsole
# =============================================================================
#
# The consent console is a SEPARATE PROCESS and is packaged the same way the server is:
# SwiftPM release binary, hand-assembled .app, ad-hoc signed, run from a per-user
# LaunchAgent. It is separate because the server ENFORCES and the console CONSENTS, and the
# whole design rests on those being two programs rather than one.
#
# A console that is not running is not a degraded console, it is NO consent path: the server
# refuses every consent-requiring capability. So this LaunchAgent is what makes the service
# usable, and `console-start` / `console-stop` exist separately from the server's own
# lifecycle for exactly that reason.

##@ [Console] Build and package

.PHONY: exactmac.console-build
exactmac.console-build: ## Build the release Swift console and its resource bundle.
	@set -uo pipefail; \
	if ! mkdir -p "$(EXACTMAC_BUILD_LOG_DIR)"; then printf '%s\n' 'ERROR: failed to create build log directory.' >&2; exit 1; fi; \
	printf '%s\n' '=== Building ExactMacConsole (release) ==='; \
	if ! cd "$(PROJECT_ROOT)/Console"; then printf '%s\n' 'ERROR: Console project directory is unavailable.' >&2; exit 1; fi; \
	if ! swift build -c release --product ExactMacConsole \
		>"$(EXACTMAC_CONSOLE_BUILD_LOG)" 2>&1; then \
		printf 'ERROR: console build failed. See %s\n' "$(EXACTMAC_CONSOLE_BUILD_LOG)" >&2; \
		tail -n 20 "$(EXACTMAC_CONSOLE_BUILD_LOG)" >&2; \
		exit 1; \
	fi; \
	if [ ! -x "$(EXACTMAC_CONSOLE_BIN)" ]; then printf 'ERROR: console binary not found: %s\n' "$(EXACTMAC_CONSOLE_BIN)" >&2; exit 1; fi; \
	printf 'Console binary built: %s\n' "$(EXACTMAC_CONSOLE_BIN)"

.PHONY: exactmac.console-app
exactmac.console-app: ## Create a clean ExactMacConsole.app, including its SwiftPM resources.
	@set -u; \
	validate_xml_value() { value="$$1"; name="$$2"; case "$$value" in *'<'*|*'>'*) printf 'ERROR: %s contains XML-significant characters.\n' "$$name" >&2; exit 1;; esac; }; \
	validate_xml_value "$$EXACTMAC_CONSOLE_APP_NAME" EXACTMAC_CONSOLE_APP_NAME; \
	validate_xml_value "$$EXACTMAC_CONSOLE_BUNDLE_ID" EXACTMAC_CONSOLE_BUNDLE_ID; \
	validate_xml_value "$$EXACTMAC_CONSOLE_VERSION" EXACTMAC_CONSOLE_VERSION; \
	validate_xml_value "$$EXACTMAC_CONSOLE_BUILD_VERSION" EXACTMAC_CONSOLE_BUILD_VERSION; \
	validate_xml_value "$$EXACTMAC_CONSOLE_MIN_MACOS" EXACTMAC_CONSOLE_MIN_MACOS; \
	validate_xml_value "$$EXACTMAC_CONSOLE_APP_EXECUTABLE" EXACTMAC_CONSOLE_APP_EXECUTABLE; \
	if launchctl print "$(EXACTMAC_CONSOLE_SERVICE_TARGET)" >/dev/null 2>&1; then \
		printf '%s\n' "ERROR: console service is loaded; run 'gmake exactmac.console-stop' before replacing the app." >&2; \
		exit 1; \
	fi; \
	if [ ! -x "$(EXACTMAC_CONSOLE_BIN)" ]; then \
		printf 'ERROR: console binary not found: %s\n' "$(EXACTMAC_CONSOLE_BIN)" >&2; \
		printf '%s\n' "Run 'gmake exactmac.console-build' first." >&2; \
		exit 1; \
	fi; \
	if [ ! -d "$(EXACTMAC_CONSOLE_REQUIRED_RESOURCE_BUNDLE)" ]; then \
		printf 'ERROR: required SwiftPM resource bundle not found: %s\n' "$(EXACTMAC_CONSOLE_REQUIRED_RESOURCE_BUNDLE)" >&2; \
		printf '%s\n' "Run 'gmake exactmac.console-build' first." >&2; \
		exit 1; \
	fi; \
	printf '%s\n' '=== Creating staged console bundle ==='; \
	if ! rm -rf "$(EXACTMAC_CONSOLE_STAGING_DIR)"; then printf '%s\n' 'ERROR: failed to clear console bundle staging directory.' >&2; exit 1; fi; \
	if ! mkdir -p "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/MacOS" "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/Resources"; then printf '%s\n' 'ERROR: failed to create console bundle staging directories.' >&2; exit 1; fi; \
	if ! install -m 0755 "$(EXACTMAC_CONSOLE_BIN)" "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/MacOS/$(EXACTMAC_CONSOLE_APP_NAME)"; then printf '%s\n' 'ERROR: failed to install console executable into bundle.' >&2; exit 1; fi; \
	if ! install -m 0644 "$(PROJECT_ROOT)/Console/Resources/AppIcon.icns" "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/Resources/AppIcon.icns"; then printf '%s\n' 'ERROR: failed to install console AppIcon.icns.' >&2; exit 1; fi; \
	if ! install -m 0644 "$(PROJECT_ROOT)/Console/Resources/MenuBarGlyph.svg" "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/Resources/MenuBarGlyph.svg"; then printf '%s\n' 'ERROR: failed to install console MenuBarGlyph.svg.' >&2; exit 1; fi; \
	if ! install -m 0644 "$(PROJECT_ROOT)/Console/Resources/MenuBarGlyph.png" "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/Resources/MenuBarGlyph.png"; then printf '%s\n' 'ERROR: failed to install console MenuBarGlyph.png.' >&2; exit 1; fi; \
	if ! install -m 0644 "$(PROJECT_ROOT)/Console/Resources/MenuBarGlyph@2x.png" "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/Resources/MenuBarGlyph@2x.png"; then printf '%s\n' 'ERROR: failed to install console MenuBarGlyph@2x.png.' >&2; exit 1; fi; \
	if ! printf '%s\n' "$$EXACTMAC_CONSOLE_INFO_PLIST_E" > "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/Info.plist"; then printf '%s\n' 'ERROR: failed to write console Info.plist.' >&2; exit 1; fi; \
	if ! printf 'APPL????' > "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/PkgInfo"; then printf '%s\n' 'ERROR: failed to write PkgInfo.' >&2; exit 1; fi; \
	resource_count=0; \
	for resource_bundle in "$(EXACTMAC_CONSOLE_BUILD_DIR)"/*.bundle; do \
		[ -d "$$resource_bundle" ] || continue; \
		resource_name=$$(basename "$$resource_bundle"); \
		if ! ditto "$$resource_bundle" "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/Resources/$$resource_name"; then printf 'ERROR: failed to copy console resource bundle: %s\n' "$$resource_bundle" >&2; exit 1; fi; \
		resource_count=$$((resource_count + 1)); \
	done; \
	if [ "$$resource_count" -eq 0 ]; then \
		printf '%s\n' 'ERROR: no SwiftPM .bundle resources were copied.' >&2; \
		exit 1; \
	fi; \
	if ! plutil -lint "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/Info.plist"; then printf '%s\n' 'ERROR: generated console Info.plist is invalid.' >&2; exit 1; fi; \
	if [ ! -d "$(EXACTMAC_CONSOLE_STAGING_DIR)/Contents/Resources/$(EXACTMAC_CONSOLE_RESOURCE_BUNDLE_NAME)" ]; then \
		printf 'ERROR: required console resource bundle missing: %s\n' "$(EXACTMAC_CONSOLE_RESOURCE_BUNDLE_NAME)" >&2; \
		exit 1; \
	fi; \
	if ! rm -rf "$(EXACTMAC_CONSOLE_APP_DIR)"; then printf '%s\n' 'ERROR: failed to replace installed console app directory.' >&2; exit 1; fi; \
	if ! mkdir -p "$(dir $(EXACTMAC_CONSOLE_APP_DIR))"; then printf '%s\n' 'ERROR: failed to create console app parent directory.' >&2; exit 1; fi; \
	if ! mv "$(EXACTMAC_CONSOLE_STAGING_DIR)" "$(EXACTMAC_CONSOLE_APP_DIR)"; then printf '%s\n' 'ERROR: failed to install staged console bundle.' >&2; exit 1; fi; \
	printf 'Console bundle created: %s (%s SwiftPM resource bundle(s))\n' "$(EXACTMAC_CONSOLE_APP_DIR)" "$$resource_count"

.PHONY: exactmac.console-sign
exactmac.console-sign: private SHELL := /bin/bash
exactmac.console-sign: ## Ad-hoc sign the console .app and verify it strictly.
	@set -uo pipefail; \
	if [ ! -x "$(EXACTMAC_CONSOLE_APP_EXECUTABLE)" ]; then \
		printf '%s\n' "ERROR: console bundle is missing; run 'gmake exactmac.console-app' first." >&2; \
		exit 1; \
	fi; \
	if launchctl print "$(EXACTMAC_CONSOLE_SERVICE_TARGET)" >/dev/null 2>&1; then \
		printf '%s\n' "ERROR: console service is loaded; run 'gmake exactmac.console-stop' before signing." >&2; \
		exit 1; \
	fi; \
	if ! chmod -R u+w "$(EXACTMAC_CONSOLE_APP_DIR)"; then printf '%s\n' 'ERROR: failed to make console app writable for signing.' >&2; exit 1; fi; \
	if ! xattr -cr "$(EXACTMAC_CONSOLE_APP_DIR)"; then printf '%s\n' 'ERROR: failed to clear console app extended attributes.' >&2; exit 1; fi; \
	printf '=== Signing console with identity: %s ===\n' "$(EXACTMAC_SIGN_IDENTITY)"; \
	if ! codesign --force --sign "$(EXACTMAC_SIGN_IDENTITY)" "$(EXACTMAC_CONSOLE_APP_DIR)"; then printf '%s\n' 'ERROR: console codesign failed.' >&2; exit 1; fi; \
	if ! codesign --verify --deep --strict "$(EXACTMAC_CONSOLE_APP_DIR)"; then printf '%s\n' 'ERROR: console codesign verification failed.' >&2; exit 1; fi; \
	printf 'Console signature verified: %s\n' "$(EXACTMAC_CONSOLE_APP_DIR)"

.PHONY: exactmac.console-register
exactmac.console-register: ## Register the signed console .app with LaunchServices.
	@set -u; \
	if [ ! -d "$(EXACTMAC_CONSOLE_APP_DIR)" ]; then \
		printf '%s\n' 'ERROR: console bundle is missing; run console-app and console-sign first.' >&2; \
		exit 1; \
	fi; \
	if ! codesign --verify --deep --strict "$(EXACTMAC_CONSOLE_APP_DIR)"; then printf '%s\n' 'ERROR: console signature verification failed.' >&2; exit 1; fi; \
	if ! "$(EXACTMAC_LSREGISTER)" -f "$(EXACTMAC_CONSOLE_APP_DIR)"; then printf '%s\n' 'ERROR: console LaunchServices registration failed.' >&2; exit 1; fi; \
	printf 'Registered %s (%s) with LaunchServices.\n' "$(EXACTMAC_CONSOLE_APP_DIR)" "$(EXACTMAC_CONSOLE_BUNDLE_ID)"

##@ [Console] LaunchAgent

.PHONY: exactmac.console-install
exactmac.console-install: ## Build, sign, install and register the app, then retire the superseded LaunchAgents.
	@# ONE ACTION, BECAUSE AN UPGRADE THAT NEEDS A SECOND COMMAND IS AN UPGRADE SOMEONE DOES
	@# NOT FINISH. The old two-process install left a plist in ~/Library/LaunchAgents and a
	@# job in the launchd domain, and the app has to take over from it: building the bundle
	@# and leaving the old agent running leaves two processes contending for
	@# ~/Library/Caches/exactmac.sock, and the second to arrive loses the pathname claim and
	@# exits with a refusal an operator reads as a broken install.
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos.all
	@set -u; \
	if ! codesign --verify --deep --strict "$(MACOS_BUNDLE_DIR)"; then printf '%s\n' 'ERROR: the assembled bundle failed signature verification.' >&2; exit 1; fi; \
	if ! mkdir -p "$(dir $(EXACTMAC_CONSOLE_APP_DIR))"; then printf '%s\n' 'ERROR: could not create the applications directory.' >&2; exit 1; fi; \
	rm -rf "$(EXACTMAC_CONSOLE_APP_DIR)" "$(EXACTMAC_CONSOLE_STAGING_DIR)"; \
	if ! ditto "$(MACOS_BUNDLE_DIR)" "$(EXACTMAC_CONSOLE_APP_DIR)"; then printf '%s\n' 'ERROR: failed to copy the app into Applications.' >&2; exit 1; fi; \
	if ! codesign --verify --deep --strict "$(EXACTMAC_CONSOLE_APP_DIR)"; then printf '%s\n' 'ERROR: the installed bundle failed signature verification.' >&2; exit 1; fi; \
	if ! "$(EXACTMAC_LSREGISTER)" -f "$(EXACTMAC_CONSOLE_APP_DIR)"; then printf '%s\n' 'ERROR: LaunchServices registration failed.' >&2; exit 1; fi; \
	mkdir -p "$(EXACTMAC_STATE_DIR)"; chmod 700 "$(EXACTMAC_STATE_DIR)"; \
	printf 'Installed: %s\n' "$(EXACTMAC_CONSOLE_APP_DIR)"
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory exactmac.retire-launchagents
	@printf '%s\n' ''
	@printf '%s\n' 'Launch it from Applications. To have it start at login, turn on the toggle in'
	@printf '%s\n' 'its menu bar item once; the app registers itself through'
	@printf '%s\n' 'ServiceManagement.SMAppService.mainApp, and macOS may ask you to approve that in'
	@printf '%s\n' 'System Settings > General > Login Items. There is no LaunchAgent any more, so'
	@printf '%s\n' 'nothing starts it until you ask for that.'
	@printf '%s\n' ''
	@printf '%s\n' 'Accessibility and Screen Recording are granted to a bundle identity, and this is'
	@printf '%s\n' 'the one change of identity, so macOS will ask for both again exactly once.'

.PHONY: exactmac.console-launchd
exactmac.console-launchd: ## Retired: refuses to write or bootstrap a console LaunchAgent.
	@printf '%s\n' 'ERROR: installing a console LaunchAgent is retired.' >&2; \
	printf '%s\n' 'The ExactMac app hosts the gRPC server in its own process and registers itself' >&2; \
	printf '%s\n' 'for start-at-login through ServiceManagement.SMAppService.mainApp. A second' >&2; \
	printf '%s\n' 'launchd-managed process serving the same socket is the two-program architecture' >&2; \
	printf '%s\n' 'this work removed, and it would contend for the pathname.' >&2; \
	printf '%s\n' '' >&2; \
	printf '%s\n' '  to retire the old LaunchAgent:  gmake exactmac.retire-launchagents' >&2; \
	printf '%s\n' '  to report what is installed:     gmake exactmac.retire-launchagents-status' >&2; \
	printf '%s\n' '  to build and sign the app:      gmake macos.all' >&2; \
	exit 1
.PHONY: exactmac.console-start
exactmac.console-start: ## Retired: refuses to start a console LaunchAgent.
	@# THE PLAINEST OF THE THREE, AND THE ONE MOST WORTH REFUSING. Starting a superseded job
	@# is how it comes back: `exactmac.retire-launchagents` unloads it, and the next person
	@# who runs this to "just start the console again" has reinstalled the two-program
	@# architecture without a plist ever being written. A clean error is the whole behaviour.
	@printf '%s\n' 'ERROR: starting a console LaunchAgent is retired.' >&2; \
	printf '%s\n' 'The ExactMac app is the service. Launch it from Applications.' >&2; \
	printf '%s\n' '' >&2; \
	printf '%s\n' '  to retire the old LaunchAgent:  gmake exactmac.retire-launchagents' >&2; \
	printf '%s\n' '  to report what is installed:     gmake exactmac.retire-launchagents-status' >&2; \
	exit 1

.PHONY: exactmac.console-stop
exactmac.console-stop: ## Stop the console service, keeping the bundle and the plist.
	@set -u; \
	console_service_absent() { output=$$(launchctl print "$(EXACTMAC_CONSOLE_SERVICE_TARGET)" 2>&1); status=$$?; [ "$$status" -ne 0 ] && printf '%s\n' "$$output" | grep -Eq 'Could not find service|No such process|service does not exist'; }; \
	if launchctl bootout "$(EXACTMAC_CONSOLE_SERVICE_TARGET)" >/dev/null 2>&1; then \
		printf 'Console service stopped: %s\n' "$(EXACTMAC_CONSOLE_SERVICE_TARGET)"; \
	elif console_service_absent; then \
		printf 'Console service is not loaded: %s\n' "$(EXACTMAC_CONSOLE_SERVICE_TARGET)"; \
	else \
		printf '%s\n' 'ERROR: could not confirm console bootout.' >&2; \
		exit 1; \
	fi

.PHONY: exactmac.console-uninstall
exactmac.console-uninstall: ## Remove the installed app and the socket. The state directory is left.
	@# THE APP IS STOPPED FIRST, because it holds the socket pathname under a lock the kernel
	@# releases only when it dies. Removing a claimed node underneath a live server leaves the
	@# next start refusing to bind, and the refusal names a socket that is not there.
	@set -u; \
	if pgrep -f "$(EXACTMAC_CONSOLE_APP_DIR)/Contents/MacOS" >/dev/null 2>&1; then \
		osascript -e 'quit app "$(EXACTMAC_CONSOLE_APP_NAME)"' >/dev/null 2>&1 || true; \
		attempt=0; \
		while pgrep -f "$(EXACTMAC_CONSOLE_APP_DIR)/Contents/MacOS" >/dev/null 2>&1 && [ "$$attempt" -lt 5 ]; do sleep 1; attempt=$$((attempt + 1)); done; \
		if pgrep -f "$(EXACTMAC_CONSOLE_APP_DIR)/Contents/MacOS" >/dev/null 2>&1; then printf '%s\n' 'ERROR: the app is still running; quit it and run this again.' >&2; exit 1; fi; \
	fi; \
	if [ -d "$(EXACTMAC_CONSOLE_APP_DIR)" ]; then "$(EXACTMAC_LSREGISTER)" -u "$(EXACTMAC_CONSOLE_APP_DIR)" >/dev/null 2>&1 || true; fi; \
	rm -rf "$(EXACTMAC_CONSOLE_APP_DIR)" "$(EXACTMAC_CONSOLE_STAGING_DIR)"; \
	rm -f "$(EXACTMAC_SOCKET)" "$(EXACTMAC_SOCKET).owner"; \
	rm -f "$(EXACTMAC_CONSOLE_STDOUT_LOG)" "$(EXACTMAC_CONSOLE_STDERR_LOG)"; \
	printf 'Removed: %s\n' "$(EXACTMAC_CONSOLE_APP_DIR)"; \
	printf '%s\n' ''; \
	printf '%s\n' 'NOT removed: the login item the app registered for itself. It belongs to the'; \
	printf '%s\n' 'bundle that created it and macOS removes it when the bundle goes, but it can'; \
	printf '%s\n' 'also be turned off in System Settings > General > Login Items.'; \
	printf '%s\n' ''; \
	printf '%s\n' 'NOT removed: $(EXACTMAC_STATE_DIR)'; \
	printf '%s\n' '  that is your grant store and decision log. Removing it is a separate,'; \
	printf '%s\n' '  deliberate act: rm -rf $(EXACTMAC_STATE_DIR)'

.PHONY: exactmac.console-status
# NO LAUNCHD PROBE HERE, and the omission is deliberate. There is no longer anything launchd
# can be holding: the console IS the app, started by the operator opening it, and it
# registers itself for start-at-login through SMAppService rather than through a job.
# Reporting "Service: not loaded" every time would have described a service that cannot
# exist, and would have sent nobody looking for the thing that actually decides it — the
# login-item registration, which lives inside the app and is visible in System Settings.
exactmac.console-status: ## Report the console's bundle, signature, and server socket.
	@set -u; \
	printf '  App:       %s\n' "$(EXACTMAC_CONSOLE_APP_DIR)"; \
	printf '  Bundle ID: %s\n' "$(EXACTMAC_CONSOLE_BUNDLE_ID)"; \
	printf '  Server socket: %s\n' "$(EXACTMAC_SOCKET)"; \
	printf '  State dir:     %s\n' "$(EXACTMAC_STATE_DIR)"; \
	if [ -d "$(EXACTMAC_CONSOLE_APP_DIR)" ]; then \
		if codesign --verify --deep --strict "$(EXACTMAC_CONSOLE_APP_DIR)" 2>/dev/null; then printf '  Signature: verified\n'; else printf '  Signature: MISSING OR INVALID\n'; fi; \
		ls -ld "$(EXACTMAC_CONSOLE_APP_DIR)"; \
	else printf '  Bundle:    not installed\n'; fi; \
	printf '  Start at login:  ask the app, or System Settings > General > Login Items\n'

##@ [Console] LaunchAgent Retirement

# The app is the product now: one process that hosts the gRPC server and presents the
# operator's consent prompt itself. It registers for start-at-login through
# `ServiceManagement.SMAppService.mainApp` and does not need a hand-written LaunchAgent.
# These targets retire the two the old two-process deployment installed.
#
# WHY THIS IS NOT JUST `rm`. Both a loaded job and an installed plist are live state, and
# a plist alone is not inert: launchd will bootstrap it again at the next login, so a
# retirement that only removed the file would look complete and resurrect the server on the
# next reboot. The order is therefore bootout, VERIFY ABSENCE, then move the file — and a
# bootout whose result cannot be confirmed stops the run rather than continuing, because
# the alternative is reporting a clean retirement over a process that is still serving.
#
# IT IS IDEMPOTENT AND REVERSIBLE. Every step checks the state it is about to change and
# reports "already retired" instead of failing, so running it twice is the same as running
# it once. Nothing is deleted: plists are moved into the archive directory below, and
# `exactmac.restore-launchagents` puts them back and re-bootstraps them. Idempotence is why
# this is safe to wire into an upgrade path; reversibility is why it is safe to run at all
# on a machine whose operator is mid-task.
#
# WHAT IT DELIBERATELY DOES NOT TOUCH: any login item the app registered for itself through
# SMAppService. That registration belongs to the bundle that created it and is revoked
# through System Settings or by the app; reaching in and removing it from here would leave
# the app believing it is registered for start-at-login when it is not.

# The two labels the old deployment installed, as a list the recipes iterate.
EXACTMAC_RETIRED_LABELS := $(EXACTMAC_CONSOLE_BUNDLE_ID) $(EXACTMAC_BUNDLE_ID)
# Plists are MOVED here rather than deleted, so a mistaken retirement costs one command.
EXACTMAC_RETIRED_PLIST_DIR ?= $(EXACTMAC_STATE_DIR)retired-launchagents

# 1 reports what WOULD happen and changes nothing. It exists because the first thing anyone
# does with a target that unloads a running server is wonder what it will touch, and
# answering that should not require running it. Every mutating step below is guarded on this.
#
# IT MATTERS MORE THAN IT LOOKS. These targets act on `$(EXACTMAC_LAUNCH_DOMAIN)`, which is
# derived from `id -u` and is therefore ALWAYS the live GUI domain of whoever ran make — so
# overriding the plist paths to a scratch directory does NOT sandbox them, and the bootout
# still reaches the real jobs. A dry run is the only safe way to inspect this.
EXACTMAC_RETIRE_DRY_RUN ?= 0

.PHONY: exactmac.retire-launchagents-status
exactmac.retire-launchagents-status: ## Report which superseded LaunchAgents are installed or loaded, and change nothing.
	@set -u; \
	dry=0; \
	[ "$(EXACTMAC_RETIRE_DRY_RUN)" = "1" ] && dry=1; \
	loaded=0; installed=0; \
	agents_dir='$(patsubst %/,%,$(dir $(EXACTMAC_CONSOLE_PLIST)))'; \
	printf '%s\n' 'Superseded LaunchAgents (the app supersedes both):'; \
	for label in $(EXACTMAC_RETIRED_LABELS); do \
		target="$(EXACTMAC_LAUNCH_DOMAIN)/$$label"; \
		plist="$$agents_dir/$$label.plist"; \
		if launchctl print "$$target" >/dev/null 2>&1; then \
			state=$$(launchctl print "$$target" 2>/dev/null | sed -n 's/^[[:space:]]*state = //p' | head -1); \
			printf '  %-52s LOADED (%s)\n' "$$label" "$${state:-unknown}"; \
			loaded=$$((loaded + 1)); \
		else printf '  %-52s not loaded\n' "$$label"; fi; \
		if [ -f "$$plist" ]; then printf '  %-52s installed: %s\n' '' "$$plist"; installed=$$((installed + 1)); fi; \
	done; \
	printf '  archive would be: %s\n' '$(EXACTMAC_RETIRED_PLIST_DIR)'; \
	printf '%s\n' 'To retire them: gmake exactmac.retire-launchagents'

.PHONY: exactmac.retire-launchagents
exactmac.retire-launchagents: ## Unload and archive the superseded LaunchAgents. Idempotent; reversible with exactmac.restore-launchagents.
	@set -u; \
	dry=0; \
	[ "$(EXACTMAC_RETIRE_DRY_RUN)" = "1" ] && dry=1; \
	changed=0; \
	if [ "$$dry" -eq 0 ]; then \
		if ! mkdir -p '$(EXACTMAC_RETIRED_PLIST_DIR)'; then printf '%s\n' 'ERROR: could not create the archive directory.' >&2; exit 1; fi; \
		chmod 700 '$(EXACTMAC_RETIRED_PLIST_DIR)'; \
	fi; \
	agents_dir='$(patsubst %/,%,$(dir $(EXACTMAC_CONSOLE_PLIST)))'; \
	for label in $(EXACTMAC_RETIRED_LABELS); do \
		target="$(EXACTMAC_LAUNCH_DOMAIN)/$$label"; \
		plist="$$agents_dir/$$label.plist"; \
		archive='$(EXACTMAC_RETIRED_PLIST_DIR)'/"$$label".plist; \
		if launchctl print "$$target" >/dev/null 2>&1; then \
			if [ "$$dry" -eq 1 ]; then printf '  would unload %s\n' "$$label"; \
			else \
				printf '  unloading %s\n' "$$label"; \
				if ! launchctl bootout "$$target" >/dev/null 2>&1; then \
					printf '  %s did not bootout cleanly; confirming it is gone\n' "$$label"; \
				fi; \
				if launchctl print "$$target" >/dev/null 2>&1; then \
					printf 'ERROR: %s is still loaded after bootout; refusing to report a clean retirement.\n' "$$label" >&2; \
					exit 1; \
				fi; \
				printf '  %s is unloaded\n' "$$label"; \
			fi; changed=$$((changed + 1)); \
		else printf '  %s was not loaded\n' "$$label"; fi; \
		if [ -f "$$plist" ]; then \
			if [ "$$dry" -eq 1 ]; then printf '  would archive %s to %s\n' "$$plist" "$$archive"; \
			else \
				if [ -e "$$archive" ]; then \
					printf '  %s: replacing the previously archived plist\n' "$$label"; \
					rm -f "$$archive"; \
				fi; \
				mv "$$plist" "$$archive" || { printf 'ERROR: could not archive %s.\n' "$$plist" >&2; exit 1; }; \
				chmod 600 "$$archive"; \
				printf '  %s archived: %s\n' "$$label" "$$archive"; \
			fi; changed=$$((changed + 1)); \
		elif [ -f "$$archive" ]; then \
			printf '  %s was already retired\n' "$$label"; \
		else printf '  %s has no installed plist\n' "$$label"; fi; \
	done; \
	if [ "$$changed" -eq 0 ]; then \
		printf '%s\n' 'Nothing to retire; both LaunchAgents were already retired.'; \
	else \
		printf 'Retired. The app is the service now; turn on its menu bar toggle to have it start at login.'; \
		printf 'To put them back: gmake exactmac.restore-launchagents\n'; \
	fi

.PHONY: exactmac.restore-launchagents
exactmac.restore-launchagents: ## Put the archived LaunchAgents back and reload them. Reverses exactmac.retire-launchagents.
	@set -u; \
	dry=0; \
	[ "$(EXACTMAC_RETIRE_DRY_RUN)" = "1" ] && dry=1; \
	restored=0; \
	agents_dir='$(patsubst %/,%,$(dir $(EXACTMAC_CONSOLE_PLIST)))'; \
	for label in $(EXACTMAC_RETIRED_LABELS); do \
		target="$(EXACTMAC_LAUNCH_DOMAIN)/$$label"; \
		plist="$$agents_dir/$$label.plist"; \
		archive='$(EXACTMAC_RETIRED_PLIST_DIR)'/"$$label".plist; \
		if [ -f "$$plist" ]; then \
			printf '  %s is already installed; leaving it alone\n' "$$label"; \
		elif [ -f "$$archive" ]; then \
			if ! mkdir -p "$$(dirname "$$plist")"; then printf 'ERROR: could not create the LaunchAgents directory.\n' >&2; exit 1; fi; \
			mv "$$archive" "$$plist" || { printf 'ERROR: could not restore %s.\n' "$$plist" >&2; exit 1; }; \
			chmod 600 "$$plist"; \
			printf '  %s restored: %s\n' "$$label" "$$plist"; restored=$$((restored + 1)); \
		else printf '  %s was never retired\n' "$$label"; fi; \
		if [ -f "$$plist" ]; then \
			launchctl enable "$$target" >/dev/null 2>&1 || true; \
			launchctl bootstrap '$(EXACTMAC_LAUNCH_DOMAIN)' "$$plist" >/dev/null 2>&1 \
				|| launchctl kickstart "$$target" >/dev/null 2>&1 \
				|| printf '  WARNING: %s is installed but did not load; run "launchctl print %s" to see why.\n' "$$label" "$$target"; \
		fi; \
	done; \
	if [ "$$restored" -eq 0 ]; then printf '%s\n' 'Nothing was archived; nothing restored.'; fi

# Short aliases. The catalog uses the exactmac.* prefix for everything else in this file, and
# these exist because the deployment contract names them in that form; they forward, so there
# is one implementation of each and no second thing to keep in step.
.PHONY: console-build console-app console-sign console-install console-uninstall console-start console-stop
console-build:    exactmac.console-build
console-app:      exactmac.console-app
console-sign:     exactmac.console-sign
console-install:  exactmac.console-install
console-uninstall: exactmac.console-uninstall
console-start:    exactmac.console-start
console-stop:     exactmac.console-stop
