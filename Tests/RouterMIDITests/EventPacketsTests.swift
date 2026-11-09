import CoreMIDI
import RouterCore
import XCTest

@testable import RouterMIDI

final class EventPacketsTests: XCTestCase {
    func testEventListUsesTheMessagesProtocolAndKeepsAllWords() throws {
        for words: [UInt32] in [
            [0x2090_3C64], [0x3012_7D01, 0], [0x4090_3C00, 0xABCD_0000],
            [0x550E_7AFF, 0x80FE_FDFC, 0xFBFA_F9F8, 0xF7F6_F5F4],
            [0xD210_0000, 50_000_000, 0, 0],
        ] {
            let message = try XCTUnwrap(MIDIMessage(words: words, timestamp: 123))
            withEventList(message) { list in
                XCTAssertEqual(list.pointee.protocol, message.type <= 3 ? ._1_0 : ._2_0)
                XCTAssertEqual(decodeEventList(list), [message])
            }
        }
    }

    func testMixedUMPWidthsStayAlignedBeyondTheInlinePacketStorage() throws {
        let packets: [[UInt32]] = [
            [0x2090_3C64], [0x40B0_0100, 0x1234_5678],
            [0x5002_7AFF, 0, 0, 0], [0xB000_0000, 1, 2], [0x10F8_0000],
        ]
        let raw = (0..<32).flatMap { _ in packets }
        let expected = try raw.map { try XCTUnwrap(MIDIMessage(words: $0, timestamp: 123)) }
        let words = raw.flatMap { $0 }
        withUnsafeTemporaryAllocation(byteCount: 4096, alignment: MemoryLayout<MIDIEventList>.alignment) { storage in
            let list = storage.baseAddress!.assumingMemoryBound(to: MIDIEventList.self)
            let first = MIDIEventListInit(list, ._2_0)
            words.withUnsafeBufferPointer { buffer in
                XCTAssertNotNil(MIDIEventListAdd(list, 4096, first, 123, words.count, buffer.baseAddress!))
            }
            XCTAssertEqual(decodeEventList(UnsafePointer(list)), expected)
        }
    }
}
