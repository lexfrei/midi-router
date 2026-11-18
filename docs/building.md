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

## Mac App Store builds

The Mac App Store requires App Sandbox. `App/MIDIRouter.entitlements` enables the sandbox, Bluetooth for the system Bluetooth MIDI window, and read-write access to files chosen in open and save panels. Only the App Store targets apply it; `make app` and GitHub release builds stay unsandboxed, so existing sessions in `~/Library/Application Support/MIDI Router` keep working. A sandboxed build stores its session in `~/Library/Containers/dev.lexfrei.midi-router` instead.

```bash
make app-sandbox
make app-store TEAM_ID=<team id> BUILD_NUMBER=<build number>
```

`make app-sandbox` builds an ad-hoc-signed sandboxed application at `.build/sandbox/Build/Products/Release/MIDI Router.app` for local checks. `make app-store` archives the application, signs it with the `Apple Distribution` identity and the `MIDI Router Mac App Store` provisioning profile (override with `STORE_PROFILE`), and exports `.build/app-store/MIDI Router.pkg` signed with the `3rd Party Mac Developer Installer` identity. Both identities and the profile must be installed locally.

The App Store workflow runs when a GitHub release is published, or manually. It checks that the release tag matches `MARKETING_VERSION`, builds with `make app-store` using `<run number>.<run attempt>` as the build number, and uploads the package to App Store Connect. Submitting the build for review stays in App Store Connect. The workflow reads these repository secrets:

| Secret | Content |
| --- | --- |
| `MAS_APP_CERT_P12` | Base64 of the `Apple Distribution` certificate and private key (`.p12`) |
| `MAS_INSTALLER_CERT_P12` | Base64 of the `3rd Party Mac Developer Installer` certificate and private key (`.p12`) |
| `MAS_CERT_PASSWORD` | Password of both `.p12` files |
| `MAS_PROVISIONING_PROFILE` | Base64 of the `MIDI Router Mac App Store` provisioning profile |
| `ASC_KEY_ID` | App Store Connect API key ID (App Manager role) |
| `ASC_ISSUER_ID` | App Store Connect API issuer ID |
| `ASC_KEY_P8` | App Store Connect API private key (`.p8` text) |

Certificates and the profile expire after one year and must be renewed together with these secrets.

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

UI tests use isolated session files and Demo Mode. Session isolation does not isolate the desktop: XCTest launches windows in the logged-in GUI session. Use a dedicated macOS session when other applications must remain untouched. Native interaction tests use XCTest and assert the resulting UI state. UI targets disable parallel test workers because they share a desktop. Shortcut checks temporarily select an ASCII-capable input source and restore the previous source after each command. macOS must authorize UI automation; input failures fail the tests rather than silently skipping them.

The UI-test runner disables hardened runtime because an ad-hoc runner cannot load its test bundle with library validation. This exception does not apply to the application target.

## Dependencies

Routing uses Apple frameworks. Presentation uses the shared [ASCIIUI](https://github.com/lexfrei/ascii-ui) Swift package. Package versions are recorded in `Package.swift`, `Package.resolved` and `project.yml`.

See [protocol support](protocol-support.md) for the routing contract and remaining verification limits.
