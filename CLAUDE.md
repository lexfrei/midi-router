# MIDI Router

## Build and verification

Swift 6, macOS 14+, Xcode and XcodeGen are required. The routing libraries use only Apple frameworks. The application consumes the shared ASCIIUI Swift package for presentation. The Makefile is authoritative for build and verification commands; `project.yml` defines the generated Xcode project and application version. Do not edit generated `.xcodeproj` files.

- `make check`: strict Swift format lint and all Swift package tests, including CoreMIDI integration and hidden-window rendering tests.
- `make lint` / `make format`: check / apply the repository's Swift formatting.
- `make test`: all package tests. Run one test with `swift test --filter RoutingTests/testLayeringDoesNotMultiplyClockOrSysEx`.
- `make race-check`: package tests under Thread Sanitizer.
- `make app`: build and verify an ad-hoc-signed universal arm64/x86_64 application at `.build/xcode/Build/Products/Release/MIDI Router.app`. Override the build directory with `make app DERIVED=/absolute/path`.
- `make run`: run the development application; obtain permission before launching it alongside or replacing an active instance.
- `make ui-smoke`: accessible-control and appearance smoke tests without synthetic drag or keyboard input.
- `make ui-test`: full XCTest UI suite, including native input delivery; requires input-automation authorization and an isolated GUI session.

## Architecture and routing invariants

- `RouterCore` owns validated MIDI messages, protocol-aware routing, note ownership, sessions and persistence. Keep it independent of CoreMIDI and presentation.
- `RouterMIDI` owns real CoreMIDI endpoints, protocol selection at ports, hotplug and bounded serial event processing. UI and monitor work must not block MIDI callbacks. Monitor truncation must not drop routed events; input overflow suspends the source and releases owned notes rather than silently losing note-offs.
- `App/Sources` owns SwiftUI/AppKit presentation and application state. Studio, Route List, Desktop and Glass are presentations of the same engine, not separate routing implementations.
- Preserve full UMP packets and MIDI 2.0 note/control precision and payloads through native protocol-2 ports. CoreMIDI may upgrade legacy inputs; downconversion belongs only at legacy destinations. MIDI 2.0 transport does not imply a complete MIDI-CI responder or Profiles implementation.
- Route changes, preset recall, All Notes Off and shutdown release owned notes and sustain and clear owned MIDI 2.0 per-note controller state. Track output ownership so one source cannot reset another source's active state. Do not reset unrelated hardware.
- Session writes are atomic. Preserve unreadable sessions and keep automatic saving disabled until the user selects a recovery file with Save As.

## UI contract

- Use restrained ASCII and monospaced text. Render glyph captions with `Text(verbatim:)` so SwiftUI does not reinterpret them. Keep tab and control widths stable across selection changes.
- Routine editors and application-owned menus are in-window overlays: opening them must not resize or scroll the workspace. Anchor them at the click or triggering control, or at the keyboard-selected object's control. Freeze the anchor while displayed; flip and clamp the panel near content edges.
- Reuse the shared opaque surface and consistent application-owned dropdown/context-menu components. Keep the OS titlebar, menu bar, Settings, file dialogs and Bluetooth windows native.
- Support arrow navigation, Return/Space activation, typeahead, Escape, outside-click dismissal and focus return to the trigger. Separators and unavailable options are disabled. Show a read-only value only when no enabled alternative exists: a sole replacement for a missing selection must remain selectable.
- Use semantic light/dark colors, scalable text, Reduce Motion support and accessibility labels. Hidden-window rendering checks prove layout, not OS pointer/keyboard delivery or VoiceOver behavior.
- Keep patchbay drag connections point-to-point; SRC connectors can fan out to multiple destinations. Cable hit-testing and Delete must respect focus: text editing must never delete a route.
- Place cable labels at the curve midpoint; displace them only to resolve overlaps, retaining a connector to the anchor.
- SRC activity means MIDI receipt on the Mac, including when no outgoing route exists; it does not indicate destination audio.
- Hide saved offline devices at launch. Only an observed online-to-offline transition receives the 30-second visibility grace period. Retain routes and device configuration while offline.

## Safe verification

- Never overwrite the user's session or restart an active application without permission. Use isolated session files and Demo Mode for application tests.
- CoreMIDI tests must create private virtual endpoints and supply an explicit endpoint inventory. Never send test MIDI to physical devices or discover-and-route against the user's live setup.
- Package rendering tests use hidden windows without activating the application. Desktop GUI automation is a separate, explicit operation: UI-test session isolation does not isolate the logged-in desktop or establish VoiceOver correctness.

## Dependency updates

`.github/renovate.json` inherits `github>lexfrei/renovate-config`, matching kokoko. Repository-side configuration does not install or authorize the Renovate GitHub App.
