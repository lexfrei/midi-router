SHELL := /bin/bash
ROOT := $(CURDIR)
DERIVED := $(ROOT)/.build/xcode
APP := $(DERIVED)/Build/Products/Release/MIDI Router.app

.PHONY: check test lint format app ui-test ui-smoke race-check run

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
