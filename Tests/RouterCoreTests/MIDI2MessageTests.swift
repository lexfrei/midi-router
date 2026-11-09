import XCTest

@testable import RouterCore

final class MIDI2MessageTests: XCTestCase {
    func testChannelVoiceKeepsFullPayloadAcrossChannelChanges() throws {
        let messages: [(UInt32, UInt32)] = [
            (0x0000_3C01, 0x1234_5678), (0x0010_3C80, 0x8765_4321),
            (0x0020_0102, 0x1234_5678), (0x0030_0102, 0x8765_4321),
            (0x0040_0102, 0xFFFF_FFFE), (0x0050_0102, 0x0000_0002),
            (0x0060_3C00, 0x8000_0001), (0x0080_3C00, 0x4321_0000),
            (0x0090_3C01, 0xABCD_1234), (0x00A0_3C00, 0x1234_5678),
            (0x00B0_0100, 0x1234_5678), (0x00C0_0001, 0x5C00_0102),
            (0x00D0_0000, 0x1234_5678), (0x00E0_0000, 0x8000_0001),
            (0x00F0_3C03, 0),
        ]
        for channel in 0..<16 {
            for (header, payload) in messages {
                let words = [0x4500_0000 | header | UInt32(channel) << 16, payload]
                let message = try XCTUnwrap(MIDIMessage(words: words, timestamp: 123))
                XCTAssertEqual(message.words, words)
                XCTAssertEqual(message.group, 5)
                XCTAssertEqual(message.channel, channel + 1)
                XCTAssertEqual(
                    message.replacing(channel: 16).words, [(words[0] & ~0x000F_0000) | 0x000F_0000, payload])
                XCTAssertEqual(message.replacing(channel: 16).timestamp, 123)
            }
        }
    }

    func testZeroVelocityMIDI2NoteOnIsNotNoteOff() throws {
        let message = try XCTUnwrap(MIDIMessage(words: [0x4090_3C00, 0]))
        XCTAssertTrue(message.isNoteOn)
        XCTAssertFalse(message.isNoteOff)
        let off = try XCTUnwrap(MIDIMessage(words: [0x4080_3C00, 0xFFFF_0000]))
        XCTAssertTrue(off.isNoteOff)
        XCTAssertFalse(off.isNoteOn)
    }

    func testDataAndReservedPacketsPreserveEveryWord() throws {
        let packets: [[UInt32]] = [
            [0x0010_1234], [0x10F8_0000], [0x2090_3C64], [0x3002_7D01, 0],
            [0x4090_3C00, 0xFFFF_0000], [0x550E_7AFF, 0x80FE_FDFC, 0xFBFA_F9F8, 0xF7F6_F5F4],
            [0x6000_0000], [0x7000_0000], [0x8000_0000, 1], [0x9000_0000, 1],
            [0xA000_0000, 1], [0xB000_0000, 1, 2], [0xC000_0000, 1, 2],
            [0xD110_0000, 50_000_000, 0, 0], [0xE000_0000, 1, 2, 3], [0xF000_0101, 0, 0, 0],
            [0x5580_1234, 0x5678_9ABC, 0xDEF0_1234, 0x5678_9ABC],
            [0x5590_1234, 0x5678_9ABC, 0xDEF0_1234, 0x5678_9ABC],
        ]
        for words in packets {
            let message = try XCTUnwrap(MIDIMessage(words: words, timestamp: 123))
            XCTAssertEqual(message.words, words)
            XCTAssertEqual(message.timestamp, 123)
            XCTAssertNil(MIDIMessage(words: Array(words.dropLast())))
            XCTAssertNil(MIDIMessage(words: words + [0]))
        }
    }

    func testMalformedSysEx8IsRejected() {
        for words: [UInt32] in [
            [0x5000_0000, 0, 0, 0], [0x500F_0000, 0, 0, 0],
        ] {
            XCTAssertNil(MIDIMessage(words: words))
        }
    }

    func testMonitorShowsWholeUMPAndOnlyRealGroupNumbers() throws {
        let message = try XCTUnwrap(MIDIMessage(words: [0x4590_3C00, 0xABCD_1234]))
        XCTAssertEqual(message.umpHex, "45903C00 ABCD1234")
        XCTAssertEqual(message.groupNumber, 6)
        let stream = try XCTUnwrap(MIDIMessage(words: [0xF403_1234, 1, 2, 3]))
        XCTAssertNil(stream.groupNumber)
        XCTAssertEqual(stream.umpHex, "F4031234 00000001 00000002 00000003")
        XCTAssertNil(try XCTUnwrap(MIDIMessage(words: [0x0010_1234])).groupNumber)
    }

    func testMIDI2SummaryDoesNotTruncateVelocityControllersOrProgram() throws {
        let note = try XCTUnwrap(MIDIMessage(words: [0x4090_3C00, 0xABCD_0000]))
        XCTAssertTrue(note.summary.contains("43981"))
        let controller = try XCTUnwrap(MIDIMessage(words: [0x40B0_0100, 0x1234_5678]))
        XCTAssertTrue(controller.summary.contains("305419896"))
        let program = try XCTUnwrap(MIDIMessage(words: [0x40C0_0001, 0x5C00_0102]))
        XCTAssertTrue(program.summary.contains("92"))
        XCTAssertEqual(note.bytes, [0x40, 0x90, 0x3C, 0, 0xAB, 0xCD, 0, 0])
    }
}
