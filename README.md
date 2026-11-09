# MIDI Router

A native macOS MIDI 1.0 and MIDI 2.0 router with a SwiftUI interface and restrained, monospaced controls. Connect hardware, Bluetooth MIDI devices and DAWs without a route or device limit.

Requires macOS 14 or later. The application builds for Apple Silicon and Intel. Routing uses native Apple frameworks; shared presentation components come from [ASCIIUI](https://github.com/lexfrei/ascii-ui). There are no accounts, activation or telemetry.

## Build and run

Install Xcode and XcodeGen, then run:

```bash
make check
make app
open ".build/xcode/Build/Products/Release/MIDI Router.app"
```

`make app` creates an ad-hoc-signed local application. It is not notarized or signed with a Developer ID. `project.yml` contains the application version.

For development:

```bash
make run
make ui-smoke
make ui-test
make race-check
```

CoreMIDI tests create private virtual endpoints and supply an explicit endpoint inventory. They never subscribe or route test traffic to physical devices. UI tests use isolated session data and Demo Mode. This does not isolate the desktop: XCTest launches windows in the logged-in GUI session. Use a dedicated macOS session when other applications must remain untouched. Drag and keyboard UI tests require macOS input-automation authorization for the runner. They fail explicitly when that permission is missing, rather than reporting a skipped test as a pass. `make ui-smoke` exercises accessible controls and captures each room in light and dark appearances without synthesizing drag or keyboard events. It is a separate smoke check, not a substitute for the complete UI suite. The UI-test runner disables hardened runtime because an ad-hoc runner cannot load its test bundle with library validation; this setting does not apply to the application target.

## Routing

- Drag an input connector onto an output connector, click the connectors in sequence, or choose **New Route**. Click a cable, its label or a Terminal row to select a route and open the nonmodal inspector. Delete removes the selected route while the patchbay or route list has keyboard focus; it does not remove routes when editing inspector text.
- Cable labels stay at the curve midpoint. They move only to avoid overlapping another label or device, with a thin connector back to their anchor.
- **AUTO** preserves the incoming channel. Choosing a channel rewrites channel messages. Transposition applies to notes, polyphonic pressure and MIDI 2.0 per-note messages. Absolute Pitch 7.9 attributes and Pitch 7.25 controllers retain their fractional precision. Out-of-range pitches are dropped; rotating MIDI 2.0 note indexes remain valid identifiers.
- Add **Port Slots** in a device's editor. Input slots select a channel; output slots force one. The main connector becomes **CH OTHER**, excluding assigned channels. Channel-less messages are forwarded once per destination, not once per slot.
- **MIDI Router In** receives MIDI from other applications. **MIDI Router Out** publishes routed MIDI for other applications to receive. Configure these from the other application's MIDI preferences.
- **Bluetooth MIDI** opens macOS's pairing window. The application does not pair devices automatically.
- Device aliases, visibility, order and Desktop positions are local to this application. Hiding a device does not disable its routes. Saved offline devices are hidden at launch. Devices that disconnect while the application is running remain visible for 30 seconds, then disappear from the columns and device list. Their routes and settings are retained, and reconnection restores visibility. **Show Offline Devices** reveals them for inspection or rebinding.
- Routing continues when the window closes. **All Notes Off**, route changes, preset recall and normal quit release owned notes and sustain and clear owned MIDI 2.0 per-note controller state. These operations do not send global resets to unrelated hardware.

Studio presents a patchbay, Terminal a route list, Desktop movable endpoint panels, and Glass a patchbay with a native control overlay. All views use the same engine. The patchbay remains a point-to-point diagram in small windows and scrolls when needed. Terminal provides the keyboard-friendly list alternative. Appearance follows macOS; content size is available in the View menu and Settings.

Route, device and preset editors, including New Route and New Preset, open beside the clicked cable or triggering control. Keyboard commands use the selected object's control as their anchor. Panels flip sides near window edges and stay inside the content area without resizing or scrolling the diagram. Choices apply immediately; text values apply when entry is finished. Creation still requires an explicit Create action.

In-window dropdowns and route context menus share the inspectors' opaque surface and monospaced text. Arrow keys move through available choices, typing finds a prefix, Enter selects, and Escape or an outside click dismisses the list. Long lists scroll to the highlighted choice. Fields with no alternative selection show their value without a dropdown. The macOS menu bar, file dialogs and Bluetooth window remain system-provided. Tab selection preserves button widths.

## MIDI protocols

Native inputs and virtual ports use MIDI 2.0. MIDI 2.0 channel-voice values, note attributes, per-note controllers, groups, SysEx8, Mixed Data Sets and Flex Data retain their full payloads between compatible endpoints. CoreMIDI upgrades legacy inputs and translates messages at legacy destinations; features with no MIDI 1.0 representation cannot be preserved there. Route channels and slots apply within each group rather than merging groups.

MIDI 2.0 Note On with zero velocity remains a Note On. Note Off and generated cleanup preserve the relevant protocol, and incoming release velocity and attributes are retained. Per-note pitch state is restored before subsequent Note Ons, including after route changes. Utility timing and Stream discovery messages belong to their original connection or endpoint and are monitored rather than forwarded as musical routes.

MIDI-CI SysEx can pass through configured routes. The router does not impersonate a device or implement its own MIDI-CI Profiles or Property Exchange service. Manufacturer/profile-specific payloads remain opaque.

## Presets and monitoring

Presets save routes, slots, aliases, visibility and positions. Assign optional Program Change values from **0–127** and enable the input devices allowed to trigger them. Matching messages are consumed before channel rewriting. Unmatched or disallowed Program Change messages continue through routing. Program assignments must be unique.

SRC boxes highlight and show **Receiving** when MIDI arrives on the Mac, even without an outgoing route. This indicates input reception, not sound from a destination.

The monitor displays input and delivered events, their groups, channels, host-clock timestamps, decoded MIDI 1.0/2.0 values and complete Universal MIDI Packet (UMP) words. Bounded transfer warnings are separate from fatal faults and are included in Clear and Copy. Pause, Clear and search affect only the display. The visible history is bounded; omitted monitor records never remove routed events. Input-queue overflow suspends the affected source, releases its owned notes and exposes a Resume action rather than silently losing note-offs.

Demo Mode generates MIDI between synthetic endpoints and does not send to hardware. Leaving it restores the previous setup. It does not synthesize audio.

Sessions save atomically under Application Support. An unreadable session is preserved, and automatic saving remains disabled until **Save As** selects a recovery file. Open and Save As use the application's versioned JSON format.

## Verification and scope

The routing core, actual CoreMIDI forwarding, hotplug, persistence, application state and layout have automated tests. Thread Sanitizer covers the same package tests. Inspector layout is also tested in hidden windows without activation or desktop capture. Native pointer, keyboard and focus delivery still require an authorized, isolated GUI session through `make ui-test`.

See [protocol support](docs/protocol-support.md) for routing behavior, bounded multipart transfers, verification coverage and remaining limits. Physical MIDI 2.0 hardware, native OS input delivery and VoiceOver interaction remain unverified.

## License

BSD-3-Clause. See [LICENSE](LICENSE).
