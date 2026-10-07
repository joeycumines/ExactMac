# make/macos.mk: macOS .app packaging for the hand-assembled products.
#
# WHAT THIS IS FOR
# macOS requires a product to be an `.app` BUNDLE to be launched, signed, registered for
# start-at-login, and shown in System Settings. SwiftPM produces a bare executable, so
# something has to put the executable inside a bundle and describe it. That is all this
# module does: bundle assembly, the generated `Info.plist`, the app icon, an ad-hoc
# `codesign`, and the checks on the result.
#
# WHY IT IS NOT CALLED `xcodebuild.mk`
# NOTHING IN THIS REPOSITORY INVOKES XCODE. There is no generator, no `.xcodeproj`, and no
# `xcodebuild` call anywhere; `blueprint.json` `knowledgeStore.xcodeQuestion` was answered
# by experiment on 2026-09-26. A module named after a tool the project does not use is
# worse than no name, because the next reader greps for the tool, finds this file, and
# concludes the build depends on Xcode. Every tool below (`codesign`, `plutil`, `ditto`,
# `xattr`, `spctl`) ships with macOS. This module was previously named
# `make/xcodebuild.mk`; that name was actively misleading and is gone.
#
# The boundary is deliberate. BUILDING the product is make/swift.mk. RUNNING and INSTALLING
# it — LaunchAgent control, LaunchServices registration, health probes, install/uninstall,
# TCC, and retiring the superseded LaunchAgents — is make/exactmac.mk. This module only
# ever writes into a build directory: it installs nothing into $(HOME) and starts nothing.
# The GUI console variant's RUNNING is out of scope here for the same reason.
#
# THE DISTRIBUTION FACT, because it is the one that is easy to get wrong: spctl REJECTS an
# ad-hoc signed build, so local development is fine ad-hoc (`MACOS_SIGN_IDENTITY` defaults
# to `-`) and distribution would need a Developer ID plus notarisation. `macos.verify`
# encodes that as an expectation rather than leaving it in a comment. Ad-hoc is not a
# convenience here, it is the entire available posture on a machine with no codesigning
# identity — and `ServiceManagement.SMAppService` accepts an ad-hoc signature, which is
# what makes `macos.all` sufficient to produce a start-at-login-capable app.
#
# Every value below is overridable. The defaults package the console, the product this
# repository is currently developing; the standalone headless server is the same three
# overrides away:
#
#   gmake macos.all \
#     MACOS_APP_NAME=exactmac-server \
#     MACOS_BUNDLE_ID=io.github.joeycumines.exactmac.server \
#     MACOS_BUILD_DIR=Server/.build/release

# Overridable product identity. These are the only values that reach the Info.plist,
# so they are gated against XML below rather than trusted.
MACOS_APP_NAME ?= ExactMacConsole
MACOS_BUNDLE_ID ?= com.exactmac.console
MACOS_VERSION ?= 0.1.0
MACOS_BUILD_VERSION ?= 1
MACOS_MIN_MACOS ?= 15.0
# true keeps the product out of the Dock and the app switcher, which is right for a
# menu bar item and for an agent, and wrong for anything an operator clicks to.
MACOS_LSUI_ELEMENT ?= true
# The app icon, copied into Contents/Resources and named by CFBundleIconFile. A bundle
# with no icon shows a generic placeholder in the Dock, in Launchpad, and in the window
# list, so this is part of being a real application rather than a decoration. The source
# is a committed `.icns`; `Console/Resources/AppIcon.iconset/` and `AppIcon-2048.png` are
# its source of record and are NOT read here, so the build does not depend on `iconutil`
# or on a source image being re-rasterised.
MACOS_ICON ?= $(PROJECT_ROOT)/Console/Resources/AppIcon.icns

# Overridable paths. The bundle is assembled under the repository's own (ignored)
# .build directory, so packaging here can never disturb an installed product.
MACOS_BUILD_DIR ?= $(PROJECT_ROOT)/Console/.build/release
MACOS_BINARY ?= $(MACOS_BUILD_DIR)/$(MACOS_APP_NAME)
# SwiftPM names a package's own resource bundle <Package>_<Target>.bundle.
MACOS_REQUIRED_RESOURCE_BUNDLE ?= $(MACOS_BUILD_DIR)/$(MACOS_APP_NAME)_$(MACOS_APP_NAME).bundle
MACOS_BUNDLE_DIR ?= $(PROJECT_ROOT)/.build/macos/$(MACOS_APP_NAME).app
# Staged, then moved into place, so a failed assembly never leaves a half-built bundle
# where a working one used to be.
MACOS_STAGING_DIR := $(MACOS_BUNDLE_DIR).staging
MACOS_INFO_PLIST_PATH ?= $(MACOS_STAGING_DIR)/Contents/Info.plist
# Paths into the assembled bundle, derived rather than spelled out per target.
MACOS_BUNDLE_CONTENTS := $(MACOS_BUNDLE_DIR)/Contents
MACOS_BUNDLE_PLIST := $(MACOS_BUNDLE_CONTENTS)/Info.plist
MACOS_BUNDLE_EXECUTABLE := $(MACOS_BUNDLE_CONTENTS)/MacOS/$(MACOS_APP_NAME)
MACOS_BUNDLE_RESOURCES := $(MACOS_BUNDLE_CONTENTS)/Resources
MACOS_REQUIRED_BUNDLED_RESOURCE := $(MACOS_BUNDLE_RESOURCES)/$(notdir $(MACOS_REQUIRED_RESOURCE_BUNDLE))
MACOS_BUNDLE_ICON := $(MACOS_BUNDLE_RESOURCES)/$(notdir $(MACOS_ICON))

# Overridable tools. All of them ship with macOS; none of them require Xcode.
MACOS_CODESIGN ?= codesign
MACOS_PLUTIL ?= plutil
MACOS_DITTO ?= ditto
MACOS_XATTR ?= xattr
MACOS_SPCTL ?= spctl
MACOS_INSTALL ?= install
MACOS_TOOLS ?= $(MACOS_TOOLS_DEFAULT)
MACOS_TOOLS_DEFAULT ?= \
	$(MACOS_CODESIGN) \
	$(MACOS_PLUTIL) \
	$(MACOS_DITTO) \
	$(MACOS_XATTR) \
	$(MACOS_SPCTL) \
	$(MACOS_INSTALL)

# `-` is the ad-hoc identity. A Developer ID is worth setting for a stable TCC grant
# across rebuilds, and is required for distribution.
MACOS_SIGN_IDENTITY ?= -

# A value that reaches the generated plist as XML must not be able to close the
# element it sits in, or silently produce a bundle that plutil -lint still accepts.
MACOS_XML_UNSAFE := < > & "
define MACOS_REQUIRE_XML_SAFE_VALUE
$(if $(strip $(foreach char,$(MACOS_XML_UNSAFE),$(if $(findstring $(char),$(1)),unsafe))),\
	$(error $(2) contains an XML-significant character; refusing unsafe value))
endef
$(foreach plist_value,MACOS_APP_NAME MACOS_BUNDLE_ID MACOS_VERSION \
	MACOS_BUILD_VERSION MACOS_MIN_MACOS,\
	$(eval $(call MACOS_REQUIRE_XML_SAFE_VALUE,$($(plist_value)),$(plist_value))))

# A binary without a plist is not a bundle and a bundle without a signature is not a
# launchable product, so neither step can be defaulted away silently.
MACOS_BINARY_REQUIRED = $(or $(MACOS_BINARY),$(error MACOS_BINARY is not set. Example: make macos.bundle MACOS_BUILD_DIR=Server/.build/release))
MACOS_SIGN_IDENTITY_REQUIRED = $(or $(MACOS_SIGN_IDENTITY),$(error MACOS_SIGN_IDENTITY is not set; use '-' for an ad-hoc signature))
# The icon is a requirement rather than a nicety, and the check is at parse time so a
# missing or unreadable source fails before any staging directory is created.
MACOS_ICON_REQUIRED = $(or $(wildcard $(MACOS_ICON)),$(error MACOS_ICON is not a readable file: $(MACOS_ICON)))

# The one check here that PASSES when a tool reports failure, so it is expressed as an
# expectation rather than as a branch: spctl rejects an ad-hoc signature, therefore
# `rejected` is the correct verdict for identity `-` and `accepted` is the correct
# verdict for anything else. A Developer ID build that Gatekeeper refuses is a real
# defect and fails.
MACOS_AD_HOC ?= $(filter -,$(MACOS_SIGN_IDENTITY))
MACOS_GATEKEEPER_EXPECTED ?= $(if $(MACOS_AD_HOC),rejected,accepted)
MACOS_GATEKEEPER_NOTE ?= $(if $(MACOS_AD_HOC),spctl rejects an ad-hoc signature; distribution would need a Developer ID and notarisation,Gatekeeper accepted the signature)

# The generated Info.plist, as a value rather than as a file written at parse time, so
# that it is regenerated whenever the identity above changes.
#
# CFBundleIconFile IS THE APP ICON'S ENTRY POINT, and it is emitted only when an icon
# source was named, because a plist that names a missing file is worse than one that
# names none: the Finder shows a broken-icon placeholder instead of a generic one.
#
# NOTE WHAT IS *NOT* HERE: there is no embedded LaunchAgent plist under
# Contents/Library/LaunchAgents, and there must not be one. The app registers ITSELF for
# start-at-login through `ServiceManagement.SMAppService.mainApp`, which registers the
# containing bundle and requires only that it be code signed. The
# `SMAppService.agent(plistName:)` variant is a different API that DOES require a plist at
# that path, and confusing the two is how a repository ends up shipping a hand-written
# LaunchAgent for an app that is supposed to be self-registering. See
# make/exactmac.mk for retiring the LaunchAgents this app supersedes.
define MACOS_INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$(MACOS_APP_NAME)</string>
    <key>CFBundleExecutable</key>
    <string>$(MACOS_APP_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(MACOS_BUNDLE_ID)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
$(if $(wildcard $(MACOS_ICON)),\
    <key>CFBundleIconFile</key>\
    <string>$(notdir $(MACOS_ICON))</string>)\
    <key>CFBundleName</key>
    <string>$(MACOS_APP_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MACOS_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(MACOS_BUILD_VERSION)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(MACOS_MIN_MACOS)</string>
$(if $(filter true,$(MACOS_LSUI_ELEMENT)),\
    <key>LSUIElement</key>\
    <true/>)\
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
endef

# A value holding newlines cannot be expanded into a recipe line — make would split it
# into two shell commands and run the XML as a script — so it is exported instead and
# read by the shell.
export MACOS_INFO_PLIST_E := $(MACOS_INFO_PLIST)

##@ [macOS] Build Targets

# THE BUILD IS A TARGET BECAUSE `macos.all` WAS PACKAGING WHATEVER WAS ALREADY THERE.
# `macos.bundle` requires a release product and says "build it first" when there is none, but
# nothing built it, so `macos.all` -- the target the install path runs -- assembled whatever
# binary happened to be in the build directory. A source change reached the bundle only after
# someone remembered to run `swift build` by hand, and a check that assembles a bundle and
# launches it was verifying a stale binary without saying so. Found by a negative control:
# editing the app so it installed a consent handler in headless mode changed nothing the check
# reported, because the checked binary predated the edit.
.PHONY: macos.build
macos.build: macos.require-tools ## Build the release product the bundle is assembled from.
	@printf '%s\n' '=== Building $(MACOS_APP_NAME) (release) ==='; \
	if ! cd "$(dir $(MACOS_BUILD_DIR))"; then printf '%s\n' 'ERROR: the build directory is unavailable.' >&2; exit 1; fi; \
	if ! swift build -c release --product "$(MACOS_APP_NAME)"; then printf '%s\n' 'ERROR: the release build failed.' >&2; exit 1; fi

##@ [macOS] Bundle Targets

.PHONY: macos.all
macos.all: macos.build macos.bundle macos.sign macos.verify ## Assemble, sign, then verify the .app (the three phases, in order).
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos.bundle
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos.sign
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos.verify

.PHONY: macos.plist
macos.plist: macos.require-tools ## Generate the bundle Info.plist and lint it.
	@mkdir -p '$(dir $(MACOS_INFO_PLIST_PATH))'
	@printf '%s\n' "$$MACOS_INFO_PLIST_E" >'$(MACOS_INFO_PLIST_PATH)'
	@$(MACOS_PLUTIL) -lint '$(MACOS_INFO_PLIST_PATH)'
	@printf 'Info.plist: %s\n' '$(MACOS_INFO_PLIST_PATH)'

.PHONY: macos.bundle
macos.bundle: macos.require-tools macos.build ## Create a clean .app from the SwiftPM release product, icon included.
	@test -f '$(MACOS_ICON_REQUIRED)' || { printf 'ERROR: no app icon at %s; a bundle without one shows a placeholder in the Dock and the window list.\n' '$(MACOS_ICON)' >&2; exit 1; }
	@test -x '$(MACOS_BINARY_REQUIRED)' || { printf 'ERROR: no product binary at %s; build the release product first.\n' '$(MACOS_BINARY)' >&2; exit 1; }
	@test -d '$(MACOS_REQUIRED_RESOURCE_BUNDLE)' || { printf 'ERROR: no SwiftPM resource bundle at %s.\n' '$(MACOS_REQUIRED_RESOURCE_BUNDLE)' >&2; exit 1; }
	@rm -rf '$(MACOS_STAGING_DIR)'
	@mkdir -p '$(MACOS_STAGING_DIR)/Contents/MacOS' '$(MACOS_STAGING_DIR)/Contents/Resources'
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory macos.plist
	@$(MACOS_INSTALL) -m 0755 '$(MACOS_BINARY)' '$(MACOS_STAGING_DIR)/Contents/MacOS/$(MACOS_APP_NAME)'
	@printf 'APPL????' >'$(MACOS_STAGING_DIR)/Contents/PkgInfo'
	@for resource_bundle in '$(MACOS_BUILD_DIR)'/*.bundle; do \
		[ -d "$$resource_bundle" ] || continue; \
		$(MACOS_DITTO) "$$resource_bundle" '$(MACOS_STAGING_DIR)/Contents/Resources/'$$(basename "$$resource_bundle") || exit 1; \
	done
	@$(MACOS_INSTALL) -m 0644 '$(MACOS_ICON_REQUIRED)' '$(MACOS_STAGING_DIR)/Contents/Resources/$(notdir $(MACOS_ICON))'
	@test -d '$(MACOS_STAGING_DIR)/Contents/Resources/$(notdir $(MACOS_REQUIRED_RESOURCE_BUNDLE))' || { printf 'ERROR: the required resource bundle was not assembled.\n' >&2; exit 1; }
	@rm -rf '$(MACOS_BUNDLE_DIR)'
	@mkdir -p '$(dir $(MACOS_BUNDLE_DIR))'
	@mv '$(MACOS_STAGING_DIR)' '$(MACOS_BUNDLE_DIR)'
	@printf 'Bundle assembled: %s\n' '$(MACOS_BUNDLE_DIR)'

.PHONY: macos.sign
macos.sign: macos.require-tools ## Sign the assembled .app and verify it strictly.
	@test -d '$(MACOS_BUNDLE_DIR)' || { printf "ERROR: no bundle at %s; run 'gmake macos.bundle' first.\n" '$(MACOS_BUNDLE_DIR)' >&2; exit 1; }
	@chmod -R u+w '$(MACOS_BUNDLE_DIR)'
	@$(MACOS_XATTR) -cr '$(MACOS_BUNDLE_DIR)'
	@$(MACOS_CODESIGN) --force --sign '$(MACOS_SIGN_IDENTITY_REQUIRED)' '$(MACOS_BUNDLE_DIR)'
	@$(MACOS_CODESIGN) --verify --deep --strict --verbose=2 '$(MACOS_BUNDLE_DIR)'
	@$(MACOS_CODESIGN) -d --verbose=2 '$(MACOS_BUNDLE_DIR)' 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)='

.PHONY: macos.verify
macos.verify: macos.require-tools ## Check the assembled .app: layout, plist, icon, signature, Gatekeeper.
	@printf '%s\n' '=== Bundle layout ==='
	@test -d '$(MACOS_BUNDLE_DIR)' || { printf "ERROR: no bundle at %s; run 'gmake macos.bundle' first.\n" '$(MACOS_BUNDLE_DIR)' >&2; exit 1; }
	@test -x '$(MACOS_BUNDLE_EXECUTABLE)' || { printf 'ERROR: bundle executable is missing or not executable: %s\n' '$(MACOS_BUNDLE_EXECUTABLE)' >&2; exit 1; }
	@printf '  executable: %s\n' '$(MACOS_BUNDLE_EXECUTABLE)'
	@test -d '$(MACOS_REQUIRED_BUNDLED_RESOURCE)' || { printf 'ERROR: the resource bundle is missing from Contents/Resources: %s\n' '$(MACOS_REQUIRED_BUNDLED_RESOURCE)' >&2; exit 1; }
	@printf '  resources:  %s\n' '$(MACOS_REQUIRED_BUNDLED_RESOURCE)'
	@printf '%s\n' '=== Info.plist ==='
	@$(MACOS_PLUTIL) -lint '$(MACOS_BUNDLE_PLIST)'
	@$(MACOS_PLUTIL) -extract CFBundleIdentifier raw -o - '$(MACOS_BUNDLE_PLIST)' | grep -qx '$(MACOS_BUNDLE_ID)' || { printf 'ERROR: CFBundleIdentifier in the assembled bundle is not %s.\n' '$(MACOS_BUNDLE_ID)' >&2; exit 1; }
	@$(MACOS_PLUTIL) -extract CFBundleExecutable raw -o - '$(MACOS_BUNDLE_PLIST)' | grep -qx '$(MACOS_APP_NAME)' || { printf 'ERROR: CFBundleExecutable in the assembled bundle is not %s.\n' '$(MACOS_APP_NAME)' >&2; exit 1; }
	@printf '  identifier: %s\n' '$(MACOS_BUNDLE_ID)'
	@printf '%s\n' '=== App icon ==='
	@if $(MACOS_PLUTIL) -extract CFBundleIconFile raw -o - '$(MACOS_BUNDLE_PLIST)' >/dev/null 2>&1; then \
		declared_icon=$$($(MACOS_PLUTIL) -extract CFBundleIconFile raw -o - '$(MACOS_BUNDLE_PLIST)'); \
		test -f '$(MACOS_BUNDLE_RESOURCES)'/"$$declared_icon" || { printf 'ERROR: CFBundleIconFile names %s but Contents/Resources does not contain it.\n' "$$declared_icon" >&2; exit 1; }; \
		printf '  icon:       %s\n' "$$declared_icon"; \
	else \
		printf '  icon:       none declared (MACOS_ICON is unset)\n'; \
	fi
	@printf '%s\n' '=== Signature ==='
	@$(MACOS_CODESIGN) --verify --deep --strict --verbose=2 '$(MACOS_BUNDLE_DIR)'
	@$(MACOS_CODESIGN) -d --verbose=2 '$(MACOS_BUNDLE_DIR)' 2>&1 | grep -E '^(Signature|TeamIdentifier)='
	@printf '%s\n' '=== Gatekeeper ==='
	@$(MACOS_SPCTL) --assess --type execute '$(MACOS_BUNDLE_DIR)' >/dev/null 2>&1 && actual=accepted || actual=rejected; \
	printf '  spctl --assess: %s, expected %s\n' "$$actual" '$(MACOS_GATEKEEPER_EXPECTED)'; \
	[ "$$actual" = '$(MACOS_GATEKEEPER_EXPECTED)' ] || { printf 'ERROR: %s\n' '$(MACOS_GATEKEEPER_NOTE)' >&2; exit 1; }; \
	printf '  %s\n' '$(MACOS_GATEKEEPER_NOTE)'
	@printf '%s\n' 'Bundle verification passed.'

.PHONY: macos.register-login-item-check
macos.register-login-item-check: ## Report whether the assembled .app is eligible to register itself for start-at-login.
	@test -d '$(MACOS_BUNDLE_DIR)' || { printf "ERROR: no bundle at %s; run 'gmake macos.bundle' first.\n" '$(MACOS_BUNDLE_DIR)' >&2; exit 1; }
	@printf '%s\n' '=== Start-at-login eligibility ==='
	@printf '  bundle:      %s\n' '$(MACOS_BUNDLE_DIR)'
	@identifier=$$($(MACOS_PLUTIL) -extract CFBundleIdentifier raw -o - '$(MACOS_BUNDLE_PLIST)'); \
	printf '  identifier:  %s\n' "$$identifier"
	@if $(MACOS_CODESIGN) --verify --strict '$(MACOS_BUNDLE_DIR)' >/dev/null 2>&1; then \
		printf '  signature:   valid (%s)\n' '$(MACOS_SIGN_IDENTITY)'; \
	else \
		printf 'ERROR: the bundle is not correctly signed, so SMAppService cannot register it.\n' >&2; exit 1; \
	fi
	@printf '%s\n' 'The app registers itself through ServiceManagement.SMAppService.mainApp when you turn'
	@printf '%s\n' 'on the toggle in its menu bar item. Nothing is registered until you do.'
	@printf '%s\n' 'Nothing is registered by this module: it builds a bundle and starts nothing.'

##@ [macOS] Other Targets

.PHONY: macos.tools
macos.tools: ## Recommends the macOS command line tools this module relies on.
	@printf '%s\n' 'This module relies on the following macOS command line tools:'
	$(foreach tool,$(MACOS_TOOLS),$(_MACOS_TOOLS_TEMPLATE))
define _MACOS_TOOLS_TEMPLATE =
	@printf ' 	* %s\n' '$(tool)'

endef

.PHONY: macos.clean
macos.clean: ## Remove the staged and assembled bundles this module writes.
	@rm -rf '$(MACOS_STAGING_DIR)' '$(MACOS_BUNDLE_DIR)'

# misc targets users can ignore

# A tool that is missing should say which one it was, before the phase that needs it
# fails somewhere less legible. Deliberately undocumented, so it stays out of `help`.
.PHONY: macos.require-tools
macos.require-tools:
	@for tool in $(MACOS_TOOLS); do \
		command -v "$$tool" >/dev/null 2>&1 || { printf 'ERROR: %s is required by make/macos.mk and is not on PATH.\n' "$$tool" >&2; exit 1; }; \
	done
