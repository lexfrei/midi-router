# Building MIDI Router

MIDI Router requires macOS 14 or later, Swift 6, Xcode and XcodeGen. The Makefile defines the build and verification commands. `project.yml` is the source for the generated Xcode project and application version; do not edit the generated project.

## Build the application

From the repository root:

```bash
make check
make app
open ".build/xcode/Build/Products/Release/MIDI Router.app"
```

`make app` builds a universal arm64/x86_64 application, verifies its ad-hoc signature and checks that its BSD license is included. It does not produce a Developer ID signature or notarization.

Use a separate build directory when preparing an artifact without replacing an existing build:

```bash
make app DERIVED="$PWD/.build/release"
```

Do not launch a second instance alongside an active application without checking its virtual-port identities and session settings.

## Verify changes

| Command | Coverage |
| --- | --- |
| `make check` | Strict Swift formatting and all package tests |
| `make lint` | Strict Swift formatting only |
| `make format` | Apply Swift formatting |
| `make test` | Routing, persistence, CoreMIDI integration, application state and hidden-window rendering tests |
| `make race-check` | Package tests under Thread Sanitizer |
| `make ui-smoke` | Accessible controls and appearance captures without synthetic drag or keyboard events |
| `make ui-test` | Full XCTest UI suite, including pointer and keyboard delivery |
| `make run` | Launch the development application |

CoreMIDI tests create private virtual endpoints and supply an explicit endpoint inventory. They do not subscribe or route test traffic to physical devices. Hidden-window rendering tests check layout without activating the app; they do not establish native input delivery or VoiceOver behavior.

UI tests use isolated session files and Demo Mode. Session isolation does not isolate the desktop: XCTest launches windows in the logged-in GUI session. Use a dedicated macOS session when other applications must remain untouched. Drag and keyboard tests require macOS input-automation authorization for the runner. They fail explicitly when permission is missing rather than reporting a skipped test as a pass.

The UI-test runner disables hardened runtime because an ad-hoc runner cannot load its test bundle with library validation. This exception does not apply to the application target.

## Dependencies

Routing uses Apple frameworks. Presentation uses the shared [ASCIIUI](https://github.com/lexfrei/ascii-ui) Swift package. Package versions are recorded in `Package.swift`, `Package.resolved` and `project.yml`.

See [protocol support](protocol-support.md) for the routing contract and remaining verification limits.
