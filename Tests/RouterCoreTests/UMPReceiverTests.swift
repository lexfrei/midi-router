import XCTest

@testable import RouterCore

final class UMPReceiverTests: XCTestCase {
    func testSysEx8CountsIncludeStreamIDAndEndMayAbort() throws {
        for form in UInt32(0)...3 {
            for count in UInt32(0)...15 {
                let words = [0x5500_7AFF | form << 20 | count << 16, 0x1234_5678, 0, 0]
                if (1...14).contains(count) || (form == 3 && count == 15) {
                    let message = try XCTUnwrap(MIDIMessage(words: words))
                    XCTAssertEqual(message.words, words)
                    XCTAssertEqual(message.data1, 0x7A)
                } else {
                    XCTAssertNil(MIDIMessage(words: words))
                }
            }
        }
    }

    func testMIDI1ReceiverIgnoresReservedBitsButLegacyInputRemainsStrict() throws {
        let off = try XCTUnwrap(MIDIMessage(words: [0x2590_BC80]))
        XCTAssertEqual(off.words, [0x2590_BC80])
        XCTAssertEqual(off.data1, 0xBC)
        XCTAssertEqual(off.data2, 0x80)
        XCTAssertEqual(off.noteNumber, 60)
        XCTAssertFalse(off.isNoteOn)
        XCTAssertTrue(off.isNoteOff)
        XCTAssertEqual(off.bytes, [0x90, 60, 0])
        XCTAssertEqual(off.summary, "Note Off  60")
        XCTAssertNil(MIDIMessage(bytes: [0x90, 0xBC, 0x80]))
        XCTAssertNil(MIDIMessage(bytes: [0x90, 60, 0x80]))
        let on = try XCTUnwrap(MIDIMessage(words: [0x2590_BCE4]))
        XCTAssertTrue(on.isNoteOn)
        XCTAssertEqual(on.summary, "Note On   60  vel 100")
        XCTAssertEqual(on.endingNote().words, [0x2580_BC80])
        let sustain = try XCTUnwrap(MIDIMessage(words: [0x25B0_C0C0]))
        XCTAssertTrue(sustain.isSustain)
        XCTAssertTrue(sustain.sustainIsDown)
        XCTAssertEqual(sustain.releasingSustain().words, [0x25B0_C080])
        XCTAssertFalse(sustain.releasingSustain().sustainIsDown)
        let program = try XCTUnwrap(MIDIMessage(words: [0x25C0_DCFF]))
        XCTAssertEqual(program.programNumber, 92)
        XCTAssertEqual(program.bytes, [0xC0, 92])
        let system = try XCTUnwrap(MIDIMessage(words: [0x15F1_C0FF]))
        XCTAssertEqual(system.bytes, [0xF1, 64])
        XCTAssertEqual(try XCTUnwrap(MIDIMessage(words: [0x15F8_FFFF])).bytes, [0xF8])
    }

    func testMIDI2ReceiverPreservesReservedBitsAcrossKnownFieldChanges() throws {
        for command in UInt32(0)...15 where command != 7 {
            let words = [0x4500_FFFF | command << 20, 0xFEDC_BA98]
            let message = try XCTUnwrap(MIDIMessage(words: words))
            XCTAssertEqual(message.words, words)
            XCTAssertEqual(message.replacing(channel: 16).words, [words[0] | 0x000F_0000, words[1]])
            if message.noteNumber != nil {
                XCTAssertEqual(message.noteNumber, 127)
                XCTAssertEqual(message.replacing(note: 60).words, [words[0] & ~0x7F00 | 0x3C00, words[1]])
            }
        }
        let note = try XCTUnwrap(MIDIMessage(words: [0x4590_BC01, 0xABCD_1234]))
        XCTAssertEqual(note.transposed(by: 12)?.words, [0x4590_C801, 0xABCD_1234])
        XCTAssertEqual(note.summary, "MIDI 2 Note On   60  vel 43981")
        let program = try XCTUnwrap(MIDIMessage(words: [0x45C0_FFFF, 0xDCFF_8182]))
        XCTAssertEqual(program.programNumber, 92)
        XCTAssertEqual(program.summary, "MIDI 2 Program Change  92")
        let sustain = try XCTUnwrap(MIDIMessage(words: [0x45B0_C0FF, 0x8000_0000]))
        XCTAssertTrue(sustain.isSustain)
        XCTAssertTrue(sustain.sustainIsDown)
    }

    func testPerNoteControllerIndexRetainsAllEightBits() throws {
        for index in UInt32(0)...255 {
            let message = try XCTUnwrap(MIDIMessage(words: [0x4500_BC00 | index, 0x8000_0000]))
            XCTAssertEqual(message.noteNumber, 60)
            XCTAssertEqual(message.data2, UInt8(index))
            XCTAssertEqual(message.isPerNotePitch, index == 3)
            XCTAssertEqual(message.summary, "MIDI 2 Per-Note Registered CC 60:\(index)  2147483648")
        }
    }

    func testReservedMessageTypesHaveNoInferredGroupOrChannel() throws {
        for type: UInt32 in [0, 6, 7, 8, 9, 10, 11, 12, 14, 15] {
            let first = type << 28 | 0x0FFF_FFFF
            let words = [first] + Array(repeating: UInt32.max, count: MIDIMessage.wordCount(for: first) - 1)
            let message = try XCTUnwrap(MIDIMessage(words: words))
            XCTAssertNil(message.groupNumber)
            XCTAssertNil(message.channel)
            XCTAssertNil(message.noteNumber)
            XCTAssertEqual(message.replacing(channel: 3, note: 60).words, words)
        }
        for type: UInt32 in [1, 2, 3, 4, 13] {
            let first = type << 28 | 0x0500_0000
            let words = [first] + Array(repeating: UInt32(0), count: MIDIMessage.wordCount(for: first) - 1)
            XCTAssertEqual(try XCTUnwrap(MIDIMessage(words: words)).groupNumber, 6)
        }
    }

    func testUnknownStatusesRemainOpaque() throws {
        for words: [UInt32] in [
            [0x15F4_FFFF], [0x2570_FFFF], [0x357F_FFFF, 0xFFFF_FFFF],
            [0x4570_FFFF, 0xFFFF_FFFF], [0x557F_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF],
        ] {
            let message = try XCTUnwrap(MIDIMessage(words: words))
            XCTAssertNil(message.channel)
            XCTAssertNil(message.noteNumber)
            XCTAssertNil(message.programNumber)
            XCTAssertFalse(message.isNoteOn)
            XCTAssertFalse(message.isNoteOff)
            XCTAssertFalse(message.isSustain)
            XCTAssertEqual(message.words, words)
            XCTAssertEqual(message.replacing(channel: 3, note: 60).words, words)
            XCTAssertEqual(message.bytes.count, words.count * 4)
            XCTAssertFalse(message.summary.contains("SysEx"))
            XCTAssertFalse(message.summary.contains("Mixed Data Set"))
        }
    }

    func testSysEx7UnusedReservedBytesAreIgnoredButPayloadIsSevenBit() throws {
        let words: [UInt32] = [0x3501_7DFF, 0xFFFF_FFFF]
        let message = try XCTUnwrap(MIDIMessage(words: words))
        XCTAssertEqual(message.words, words)
        XCTAssertEqual(message.bytes, [0x7D])
        XCTAssertNil(MIDIMessage(words: [0x3501_FDFF, 0xFFFF_FFFF]))
    }
}
