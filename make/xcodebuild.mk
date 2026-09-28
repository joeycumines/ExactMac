# make/xcodebuild.mk: macOS .app packaging for the hand-assembled products.
#
# WHAT THIS IS FOR
# ExactMac does not depend on Xcode — blueprint.json, knowledgeStore.xcodeQuestion,
# answered by experiment on 2026-09-26: there is no generator, no .xcodeproj, and
# nothing in this repository invokes xcodebuild. An .app is assembled by hand from a
# SwiftPM release product, and the concerns that would otherwise belong to Xcode need
# a home, so they live here: bundle assembly, the generated Info.plist, ad-hoc
# codesign, and the checks on the resulting binary.
#
# The boundary is deliberate. BUILDING the product is make/swift.mk. RUNNING it —
# LaunchAgent control, LaunchServices registration, health probes, install/uninstall,
# TCC — is make/exactmac.mk. This module only ever writes into a build directory; it
# installs nothing into $(HOME) and starts nothing.
#
# THE DISTRIBUTION FACT, because it is the one that is easy to get wrong: spctl
# REJECTS an ad-hoc signed build, so local development is fine ad-hoc
# (XCODEBUILD_SIGN_IDENTITY defaults to `-`) and distribution would need a Developer ID
# plus notarisation. `xcodebuild.verify` encodes that as an expectation rather than
# leaving it in a comment.
#
# Every value below is overridable. The defaults package the console, the product this
# repository is currently developing; the server is the same three overrides away:
#
#   gmake xcodebuild.all \
#     XCODEBUILD_APP_NAME=ExactMacServer \
#     XCODEBUILD_BUNDLE_ID=io.github.joeycumines.exactmac.server \
#     XCODEBUILD_BUILD_DIR=Server/.build/release

# Overridable product identity. These are the only values that reach the Info.plist,
# so they are gated against XML below rather than trusted.
XCODEBUILD_APP_NAME ?= ExactMacConsole
XCODEBUILD_BUNDLE_ID ?= com.exactmac.console
XCODEBUILD_VERSION ?= 0.1.0
XCODEBUILD_BUILD_VERSION ?= 1
XCODEBUILD_MIN_MACOS ?= 15.0
# true keeps the product out of the Dock and the app switcher, which is right for a
# menu bar item and for an agent, and wrong for anything an operator clicks to.
XCODEBUILD_LSUI_ELEMENT ?= true

# Overridable paths. The bundle is assembled under the repository's own (ignored)
# .build directory, so packaging here can never disturb an installed product.
XCODEBUILD_BUILD_DIR ?= $(PROJECT_ROOT)/Console/.build/release
XCODEBUILD_BINARY ?= $(XCODEBUILD_BUILD_DIR)/$(XCODEBUILD_APP_NAME)
# SwiftPM names a package's own resource bundle <Package>_<Target>.bundle.
XCODEBUILD_REQUIRED_RESOURCE_BUNDLE ?= $(XCODEBUILD_BUILD_DIR)/$(XCODEBUILD_APP_NAME)_$(XCODEBUILD_APP_NAME).bundle
XCODEBUILD_BUNDLE_DIR ?= $(PROJECT_ROOT)/.build/xcodebuild/$(XCODEBUILD_APP_NAME).app
# Staged, then moved into place, so a failed assembly never leaves a half-built bundle
# where a working one used to be.
XCODEBUILD_STAGING_DIR := $(XCODEBUILD_BUNDLE_DIR).staging
XCODEBUILD_INFO_PLIST_PATH ?= $(XCODEBUILD_STAGING_DIR)/Contents/Info.plist
# Paths into the assembled bundle, derived rather than spelled out per target.
XCODEBUILD_BUNDLE_CONTENTS := $(XCODEBUILD_BUNDLE_DIR)/Contents
XCODEBUILD_BUNDLE_PLIST := $(XCODEBUILD_BUNDLE_CONTENTS)/Info.plist
XCODEBUILD_BUNDLE_EXECUTABLE := $(XCODEBUILD_BUNDLE_CONTENTS)/MacOS/$(XCODEBUILD_APP_NAME)
XCODEBUILD_BUNDLE_RESOURCES := $(XCODEBUILD_BUNDLE_CONTENTS)/Resources
XCODEBUILD_REQUIRED_BUNDLED_RESOURCE := $(XCODEBUILD_BUNDLE_RESOURCES)/$(notdir $(XCODEBUILD_REQUIRED_RESOURCE_BUNDLE))

# Overridable tools. All of them ship with macOS; none of them require Xcode.
XCODEBUILD_CODESIGN ?= codesign
XCODEBUILD_PLUTIL ?= plutil
XCODEBUILD_DITTO ?= ditto
XCODEBUILD_XATTR ?= xattr
XCODEBUILD_SPCTL ?= spctl
XCODEBUILD_TOOLS ?= $(XCODEBUILD_TOOLS_DEFAULT)
XCODEBUILD_TOOLS_DEFAULT ?= \
	$(XCODEBUILD_CODESIGN) \
	$(XCODEBUILD_PLUTIL) \
	$(XCODEBUILD_DITTO) \
	$(XCODEBUILD_XATTR) \
	$(XCODEBUILD_SPCTL)

# `-` is the ad-hoc identity. A Developer ID is worth setting for a stable TCC grant
# across rebuilds, and is required for distribution.
XCODEBUILD_SIGN_IDENTITY ?= -

# A value that reaches the generated plist as XML must not be able to close the
# element it sits in, or silently produce a bundle that plutil -lint still accepts.
XCODEBUILD_XML_UNSAFE := < > & "
define XCODEBUILD_REQUIRE_XML_SAFE_VALUE
$(if $(strip $(foreach char,$(XCODEBUILD_XML_UNSAFE),$(if $(findstring $(char),$(1)),unsafe))),\
	$(error $(2) contains an XML-significant character; refusing unsafe value))
endef
$(foreach plist_value,XCODEBUILD_APP_NAME XCODEBUILD_BUNDLE_ID XCODEBUILD_VERSION \
	XCODEBUILD_BUILD_VERSION XCODEBUILD_MIN_MACOS,\
	$(eval $(call XCODEBUILD_REQUIRE_XML_SAFE_VALUE,$($(plist_value)),$(plist_value))))

# A binary without a plist is not a bundle and a bundle without a signature is not a
# launchable product, so neither step can be defaulted away silently.
XCODEBUILD_BINARY_REQUIRED = $(or $(XCODEBUILD_BINARY),$(error XCODEBUILD_BINARY is not set. Example: make xcodebuild.bundle XCODEBUILD_BUILD_DIR=Server/.build/release))
XCODEBUILD_SIGN_IDENTITY_REQUIRED = $(or $(XCODEBUILD_SIGN_IDENTITY),$(error XCODEBUILD_SIGN_IDENTITY is not set; use '-' for an ad-hoc signature))

# The one check here that PASSES when a tool reports failure, so it is expressed as an
# expectation rather than as a branch: spctl rejects an ad-hoc signature, therefore
# `rejected` is the correct verdict for identity `-` and `accepted` is the correct
# verdict for anything else. A Developer ID build that Gatekeeper refuses is a real
# defect and fails.
XCODEBUILD_AD_HOC ?= $(filter -,$(XCODEBUILD_SIGN_IDENTITY))
XCODEBUILD_GATEKEEPER_EXPECTED ?= $(if $(XCODEBUILD_AD_HOC),rejected,accepted)
XCODEBUILD_GATEKEEPER_NOTE ?= $(if $(XCODEBUILD_AD_HOC),spctl rejects an ad-hoc signature; distribution would need a Developer ID and notarisation,Gatekeeper accepted the signature)

# The generated Info.plist, as a value rather than as a file written at parse time, so
# that it is regenerated whenever the identity above changes.
define XCODEBUILD_INFO_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>$(XCODEBUILD_APP_NAME)</string>
    <key>CFBundleExecutable</key>
    <string>$(XCODEBUILD_APP_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(XCODEBUILD_BUNDLE_ID)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(XCODEBUILD_APP_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$(XCODEBUILD_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(XCODEBUILD_BUILD_VERSION)</string>
    <key>LSMinimumSystemVersion</key>
    <string>$(XCODEBUILD_MIN_MACOS)</string>
$(if $(filter true,$(XCODEBUILD_LSUI_ELEMENT)),\
    <key>LSUIElement</key>\
    <true/>)\
    <key>NSHighResolutionCapable</key>\
    <true/>
</dict>
</plist>
endef

# A value holding newlines cannot be expanded into a recipe line — make would split it
# into two shell commands and run the XML as a script — so it is exported instead and
# read by the shell.
export XCODEBUILD_INFO_PLIST_E := $(XCODEBUILD_INFO_PLIST)

##@ [Xcode] Bundle Targets

.PHONY: xcodebuild.all
xcodebuild.all: ## Assemble, sign, then verify the .app (the three phases, in order).
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory xcodebuild.bundle
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory xcodebuild.sign
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory xcodebuild.verify

.PHONY: xcodebuild.plist
xcodebuild.plist: xcodebuild.require-tools ## Generate the bundle Info.plist and lint it.
	@mkdir -p '$(dir $(XCODEBUILD_INFO_PLIST_PATH))'
	@printf '%s\n' "$$XCODEBUILD_INFO_PLIST_E" >'$(XCODEBUILD_INFO_PLIST_PATH)'
	@$(XCODEBUILD_PLUTIL) -lint '$(XCODEBUILD_INFO_PLIST_PATH)'
	@printf 'Info.plist: %s\n' '$(XCODEBUILD_INFO_PLIST_PATH)'

.PHONY: xcodebuild.bundle
xcodebuild.bundle: xcodebuild.require-tools ## Create a clean .app from the SwiftPM release product.
	@test -x '$(XCODEBUILD_BINARY_REQUIRED)' || { printf 'ERROR: no product binary at %s; build the release product first.\n' '$(XCODEBUILD_BINARY)' >&2; exit 1; }
	@test -d '$(XCODEBUILD_REQUIRED_RESOURCE_BUNDLE)' || { printf 'ERROR: no SwiftPM resource bundle at %s.\n' '$(XCODEBUILD_REQUIRED_RESOURCE_BUNDLE)' >&2; exit 1; }
	@rm -rf '$(XCODEBUILD_STAGING_DIR)'
	@mkdir -p '$(XCODEBUILD_STAGING_DIR)/Contents/MacOS' '$(XCODEBUILD_STAGING_DIR)/Contents/Resources'
	+@$(MAKE) -C "$(PROJECT_ROOT)" --no-print-directory xcodebuild.plist
	@install -m 0755 '$(XCODEBUILD_BINARY)' '$(XCODEBUILD_STAGING_DIR)/Contents/MacOS/$(XCODEBUILD_APP_NAME)'
	@printf 'APPL????' >'$(XCODEBUILD_STAGING_DIR)/Contents/PkgInfo'
	@set -e; for resource_bundle in '$(XCODEBUILD_BUILD_DIR)'/*.bundle; do \
		[ -d "$$resource_bundle" ] || continue; \
		$(XCODEBUILD_DITTO) "$$resource_bundle" '$(XCODEBUILD_STAGING_DIR)/Contents/Resources/'$$(basename "$$resource_bundle"); \
	done
	@test -d '$(XCODEBUILD_STAGING_DIR)/Contents/Resources/$(notdir $(XCODEBUILD_REQUIRED_RESOURCE_BUNDLE))' || { printf 'ERROR: the required resource bundle was not assembled.\n' >&2; exit 1; }
	@rm -rf '$(XCODEBUILD_BUNDLE_DIR)'
	@mkdir -p '$(dir $(XCODEBUILD_BUNDLE_DIR))'
	@mv '$(XCODEBUILD_STAGING_DIR)' '$(XCODEBUILD_BUNDLE_DIR)'
	@printf 'Bundle assembled: %s\n' '$(XCODEBUILD_BUNDLE_DIR)'

.PHONY: xcodebuild.sign
xcodebuild.sign: xcodebuild.require-tools ## Sign the assembled .app and verify it strictly.
	@test -d '$(XCODEBUILD_BUNDLE_DIR)' || { printf "ERROR: no bundle at %s; run 'gmake xcodebuild.bundle' first.\n" '$(XCODEBUILD_BUNDLE_DIR)' >&2; exit 1; }
	@chmod -R u+w '$(XCODEBUILD_BUNDLE_DIR)'
	@$(XCODEBUILD_XATTR) -cr '$(XCODEBUILD_BUNDLE_DIR)'
	@$(XCODEBUILD_CODESIGN) --force --sign '$(XCODEBUILD_SIGN_IDENTITY_REQUIRED)' '$(XCODEBUILD_BUNDLE_DIR)'
	@$(XCODEBUILD_CODESIGN) --verify --deep --strict --verbose=2 '$(XCODEBUILD_BUNDLE_DIR)'
	@$(XCODEBUILD_CODESIGN) -d --verbose=2 '$(XCODEBUILD_BUNDLE_DIR)' 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)='

.PHONY: xcodebuild.verify
xcodebuild.verify: xcodebuild.require-tools ## Check the assembled .app: layout, plist, signature, Gatekeeper.
	@printf '%s\n' '=== Bundle layout ==='
	@test -d '$(XCODEBUILD_BUNDLE_DIR)' || { printf "ERROR: no bundle at %s; run 'gmake xcodebuild.bundle' first.\n" '$(XCODEBUILD_BUNDLE_DIR)' >&2; exit 1; }
	@test -x '$(XCODEBUILD_BUNDLE_EXECUTABLE)' || { printf 'ERROR: bundle executable is missing or not executable: %s\n' '$(XCODEBUILD_BUNDLE_EXECUTABLE)' >&2; exit 1; }
	@printf '  executable: %s\n' '$(XCODEBUILD_BUNDLE_EXECUTABLE)'
	@test -d '$(XCODEBUILD_REQUIRED_BUNDLED_RESOURCE)' || { printf 'ERROR: the resource bundle is missing from Contents/Resources: %s\n' '$(XCODEBUILD_REQUIRED_BUNDLED_RESOURCE)' >&2; exit 1; }
	@printf '  resources:  %s\n' '$(XCODEBUILD_REQUIRED_BUNDLED_RESOURCE)'
	@printf '%s\n' '=== Info.plist ==='
	@$(XCODEBUILD_PLUTIL) -lint '$(XCODEBUILD_BUNDLE_PLIST)'
	@$(XCODEBUILD_PLUTIL) -extract CFBundleIdentifier raw -o - '$(XCODEBUILD_BUNDLE_PLIST)' | grep -qx '$(XCODEBUILD_BUNDLE_ID)' || { printf 'ERROR: CFBundleIdentifier in the assembled bundle is not %s.\n' '$(XCODEBUILD_BUNDLE_ID)' >&2; exit 1; }
	@$(XCODEBUILD_PLUTIL) -extract CFBundleExecutable raw -o - '$(XCODEBUILD_BUNDLE_PLIST)' | grep -qx '$(XCODEBUILD_APP_NAME)' || { printf 'ERROR: CFBundleExecutable in the assembled bundle is not %s.\n' '$(XCODEBUILD_APP_NAME)' >&2; exit 1; }
	@printf '  identifier: %s\n' '$(XCODEBUILD_BUNDLE_ID)'
	@printf '%s\n' '=== Signature ==='
	@$(XCODEBUILD_CODESIGN) --verify --deep --strict --verbose=2 '$(XCODEBUILD_BUNDLE_DIR)'
	@$(XCODEBUILD_CODESIGN) -d --verbose=2 '$(XCODEBUILD_BUNDLE_DIR)' 2>&1 | grep -E '^(Signature|TeamIdentifier)='
	@printf '%s\n' '=== Gatekeeper ==='
	@$(XCODEBUILD_SPCTL) --assess --type execute '$(XCODEBUILD_BUNDLE_DIR)' >/dev/null 2>&1 && actual=accepted || actual=rejected; \
	printf '  spctl --assess: %s, expected %s\n' "$$actual" '$(XCODEBUILD_GATEKEEPER_EXPECTED)'; \
	[ "$$actual" = '$(XCODEBUILD_GATEKEEPER_EXPECTED)' ] || { printf 'ERROR: %s\n' '$(XCODEBUILD_GATEKEEPER_NOTE)' >&2; exit 1; }; \
	printf '  %s\n' '$(XCODEBUILD_GATEKEEPER_NOTE)'
	@printf '%s\n' 'Bundle verification passed.'

##@ [Xcode] Other Targets

.PHONY: xcodebuild.tools
xcodebuild.tools: ## Recommends the macOS command line tools this module relies on.
	@printf '%s\n' 'This module relies on the following macOS command line tools:'
	$(foreach tool,$(XCODEBUILD_TOOLS),$(_XCODEBUILD_TOOLS_TEMPLATE))
define _XCODEBUILD_TOOLS_TEMPLATE =
	@printf ' 	* %s\n' '$(tool)'

endef

.PHONY: xcodebuild.clean
xcodebuild.clean: ## Remove the staged and assembled bundles this module writes.
	@rm -rf '$(XCODEBUILD_STAGING_DIR)' '$(XCODEBUILD_BUNDLE_DIR)'

# misc targets users can ignore

# A tool that is missing should say which one it was, before the phase that needs it
# fails somewhere less legible. Deliberately undocumented, so it stays out of `help`.
.PHONY: xcodebuild.require-tools
xcodebuild.require-tools:
	@for tool in $(XCODEBUILD_TOOLS); do \
		command -v "$$tool" >/dev/null 2>&1 || { printf 'ERROR: %s is required by make/xcodebuild.mk and is not on PATH.\n' "$$tool" >&2; exit 1; }; \
	done
