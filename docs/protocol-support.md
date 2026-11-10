# Protocol support

MIDI Router requires macOS 14 or later and builds for arm64 and x86_64. It routes MIDI 1.0 and MIDI 2.0 through CoreMIDI; protocol conversion occurs at legacy destinations rather than reducing native MIDI 2.0 traffic to byte messages.

## Routing behavior

- MIDI 2.0 channel-voice values, note attributes, per-note controllers and release data retain their precision. Route channels and port slots operate within each UMP group. Unknown and reserved UMP messages retain their raw words.
- Transposition applies to notes, polyphonic pressure, per-note messages, Pitch 7.9 attributes and Pitch 7.25 controllers. Fractional pitch is preserved; unrepresentable pitches are suppressed. Note indexes remain identifiers when absolute pitch is supplied.
- Route changes release owned notes, sustain and per-note controller state. Incoming absolute-pitch state can be restored before subsequent Note Ons. Cleanup does not reset unrelated hardware.
- Program Change recall uses raw values 0–127 and an input allowlist before channel rewriting. Only matching recalls consume the message. Presets include routes, slots and device/layout settings.
- Utility timing and Stream discovery messages are monitored on their own connection rather than forwarded as musical routes. MIDI-CI SysEx passes through configured routes; the application does not implement a full MIDI-CI responder, Profiles or Property Exchange service. Manufacturer-specific payloads remain opaque.

## Multipart transfers and limits

| Message family | Behavior and limit |
| --- | --- |
| SysEx7 | Streams without accumulating the full payload. The first source owns each destination/group until the transfer ends or is interrupted. Live musical events may interrupt a transfer; a nonfatal diagnostic reports the interruption. |
| SysEx8 | Preserves payloads and accepts valid Abort packets. Until receiver-capacity discovery is implemented, routing conservatively allows one transfer per destination and uses output stream ID 0. |
| Mixed Data Sets | Tracks multipart sequences and remaps output IDs within the 16-ID space per destination/group. |
| Flex Data | Buffers at most 32 UMP packets per transfer before delivery; incomplete or invalid sequences produce diagnostics. |

The router allows at most 128 active multipart transfers. Transfers idle for 30 seconds expire when the next message is received, not from a background timer. These bounds are independent of the absence of a commercial route/device cap. Legacy outputs cannot preserve message types or precision that MIDI 1.0 cannot represent.

The monitor keeps bounded transfer warnings separate from fatal engine faults. Clear and Copy include warnings. Monitor-history truncation does not remove routed events; input-queue overflow instead suspends the affected source and releases its owned notes.

## Verification

`make check` runs formatting checks and package tests covering protocol validation, raw-word preservation, multipart ownership and interruption, note lifecycle, persistence, application state and hidden-window rendering. CoreMIDI integration tests use private virtual endpoints and an explicit inventory, never physical destinations. `make race-check` runs package tests with Thread Sanitizer.

The package suite, including CoreMIDI integration and hidden-window rendering, has passed on Apple Silicon and Intel. Hidden-window rendering checks do not establish native OS pointer/keyboard delivery or VoiceOver behavior. `make ui-smoke` checks accessible controls and appearances; `make ui-test` requires an authorized, isolated desktop session.

The UI smoke suite has passed in light and dark appearances, covering connector clicks, menu navigation, preset creation and connection cancellation. It does not exercise drag-and-drop or keyboard input.

Physical MIDI 2.0 hardware, Bluetooth pairing, packaged-application interaction on Intel, full drag and keyboard workflows, and VoiceOver interaction remain unverified.

## Specifications

- [MMA/AMEI UMP and MIDI 2.0 Protocol 1.1.2](https://amei-music.github.io/midi2.0-docs/amei-pdf/M2-104-UM_v1-1-2_UMP_and_MIDI_2-0_Protocol_Specification.pdf)
- [Apple CoreMIDI](https://developer.apple.com/documentation/coremidi)
