SHELL := /bin/bash
ROOT := $(CURDIR)
DERIVED := $(ROOT)/.build/xcode
APP := $(DERIVED)/Build/Products/Release/MIDI Router.app
ENTITLEMENTS := $(ROOT)/App/MIDIRouter.entitlements
SANDBOX_DERIVED := $(ROOT)/.build/sandbox
SANDBOX_APP := $(SANDBOX_DERIVED)/Build/Products/Release/MIDI Router.app
STORE_DIR := $(ROOT)/.build/app-store
STORE_PROFILE ?= MIDI Router Mac App Store
TEAM_ID ?=
BUILD_NUMBER ?=

.PHONY: check test lint format app app-sandbox app-store ui-test ui-smoke race-check run

check: lint test

test:
	swift test --package-path "$(ROOT)"

lint:
	swift format lint --strict --recursive "$(ROOT)/Sources" "$(ROOT)/App" "$(ROOT)/Tests" "$(ROOT)/Package.swift"

format:
	swift format format --in-place --recursive "$(ROOT)/Sources" "$(ROOT)/App" "$(ROOT)/Tests" "$(ROOT)/Package.swift"

app:
	xcodegen generate --spec "$(ROOT)/project.yml"
	xcodebuild -project "$(ROOT)/MIDIRouter.xcodeproj" -scheme MIDIRouter -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$(DERIVED)" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build
	codesign --verify --deep --strict "$(APP)"
	cmp "$(ROOT)/LICENSE" "$(APP)/Contents/Resources/LICENSE"
	@printf '\n%s\n' "$(APP)"

app-sandbox:
	xcodegen generate --spec "$(ROOT)/project.yml"
	xcodebuild -project "$(ROOT)/MIDIRouter.xcodeproj" -scheme MIDIRouter -configuration Release -destination 'generic/platform=macOS' -derivedDataPath "$(SANDBOX_DERIVED)" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO MIDI_ROUTER_ENTITLEMENTS="$(ENTITLEMENTS)" build
	codesign --verify --deep --strict "$(SANDBOX_APP)"
	codesign --display --entitlements - "$(SANDBOX_APP)" 2>/dev/null | grep -q com.apple.security.app-sandbox
	@printf '\n%s\n' "$(SANDBOX_APP)"

app-store:
	@test -n "$(TEAM_ID)" || { echo 'TEAM_ID is required' >&2; exit 1; }
	xcodegen generate --spec "$(ROOT)/project.yml"
	rm -rf "$(STORE_DIR)"
	xcodebuild -project "$(ROOT)/MIDIRouter.xcodeproj" -scheme MIDIRouter -configuration Release -destination 'generic/platform=macOS' -archivePath "$(STORE_DIR)/MIDIRouter.xcarchive" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO DEVELOPMENT_TEAM="$(TEAM_ID)" MIDI_ROUTER_ENTITLEMENTS="$(ENTITLEMENTS)" $(if $(BUILD_NUMBER),CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)") archive
	plutil -create xml1 "$(STORE_DIR)/ExportOptions.plist"
	plutil -insert method -string app-store-connect "$(STORE_DIR)/ExportOptions.plist"
	plutil -insert destination -string export "$(STORE_DIR)/ExportOptions.plist"
	plutil -insert signingStyle -string manual "$(STORE_DIR)/ExportOptions.plist"
	plutil -insert teamID -string "$(TEAM_ID)" "$(STORE_DIR)/ExportOptions.plist"
	plutil -insert signingCertificate -string 'Apple Distribution' "$(STORE_DIR)/ExportOptions.plist"
	plutil -insert installerSigningCertificate -string '3rd Party Mac Developer Installer' "$(STORE_DIR)/ExportOptions.plist"
	plutil -insert provisioningProfiles -json '{"dev.lexfrei.midi-router":"$(STORE_PROFILE)"}' "$(STORE_DIR)/ExportOptions.plist"
	xcodebuild -exportArchive -archivePath "$(STORE_DIR)/MIDIRouter.xcarchive" -exportPath "$(STORE_DIR)" -exportOptionsPlist "$(STORE_DIR)/ExportOptions.plist"
	pkgutil --check-signature "$(STORE_DIR)/MIDI Router.pkg"
	@printf '\n%s\n' "$(STORE_DIR)/MIDI Router.pkg"

ui-test:
	xcodegen generate --spec "$(ROOT)/project.yml"
	xcodebuild -project "$(ROOT)/MIDIRouter.xcodeproj" -scheme MIDIRouter -configuration Debug -destination 'platform=macOS' -derivedDataPath "$(DERIVED)" -parallel-testing-enabled NO test

ui-smoke:
	xcodegen generate --spec "$(ROOT)/project.yml"
	xcodebuild -project "$(ROOT)/MIDIRouter.xcodeproj" -scheme MIDIRouter -configuration Debug -destination 'platform=macOS' -derivedDataPath "$(DERIVED)" -parallel-testing-enabled NO -only-testing:MIDIRouterUITests/RoutingUITests/testAccessibleRoutingAndRoomLayouts test

race-check:
	swift test --package-path "$(ROOT)" --sanitize thread

run:
	swift run --package-path "$(ROOT)" midi-router
