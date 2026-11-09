import XCTest

@testable import RouterCore

final class MIDI2RoutingTests: XCTestCase {
    private func session() -> Session {
        Session(
            setup: Setup(
                ports: [
                    RouterPort(id: "in", name: "Keys", direction: .input),
                    RouterPort(id: "out", name: "Synth", direction: .output),
                ], routes: [Route(source: "in", destination: "out")]))
    }

    func testNoteOffRetainsFullVelocityAndAttributes() throws {
        var setup = session()
        setup.setup.routes[0].channel = 9
        setup.setup.routes[0].transpose = 12
        var router = try Router(session: setup)
        let on = try XCTUnwrap(MIDIMessage(words: [0x4591_3C01, 0xABCD_1234], timestamp: 123))
        let off = try XCTUnwrap(MIDIMessage(words: [0x4581_3C02, 0x8765_4321], timestamp: 456))
        XCTAssertEqual(router.receive(on, from: "in").deliveries.first?.message.words, [0x4598_4801, 0xABCD_1234])
        let delivered = try XCTUnwrap(router.receive(off, from: "in").deliveries.first?.message)
        XCTAssertEqual(delivered.words, [0x4588_4802, 0x8765_4321])
        XCTAssertEqual(delivered.timestamp, 456)
        XCTAssertTrue(router.panic().isEmpty)
    }

    func testZeroVelocityNoteIsTrackedAndEditReleasesOriginalDestination() throws {
        var setup = session()
        setup.setup.routes[0].transpose = 12
        var router = try Router(session: setup)
        let on = try XCTUnwrap(MIDIMessage(words: [0x4392_3C00, 0]))
        XCTAssertEqual(router.receive(on, from: "in").deliveries.first?.message.words, [0x4392_4800, 0])
        setup.setup.routes[0].transpose = -12
        let cleanup = try router.replaceSession(setup)
        XCTAssertEqual(cleanup.map(\.message.words), [[0x4382_4800, 0]])
        let off = try XCTUnwrap(MIDIMessage(words: [0x4382_3C00, 0x1234_0000]))
        XCTAssertTrue(router.receive(off, from: "in").deliveries.isEmpty)
        XCTAssertTrue(router.panic().isEmpty)
    }

    func testMixedProtocolOwnersDoNotReleaseEachOthersNotes() throws {
        var setup = session()
        setup.setup.ports.append(RouterPort(id: "other", name: "Other", direction: .input))
        setup.setup.routes.append(Route(source: "other", destination: "out"))
        var router = try Router(session: setup)
        _ = router.receive(.noteOn(60), from: "in")
        _ = router.receive(try XCTUnwrap(MIDIMessage(words: [0x4090_3C00, 0xABCD_0000])), from: "other")
        XCTAssertTrue(router.receive(.noteOff(60), from: "in").deliveries.isEmpty)
        let off = try XCTUnwrap(MIDIMessage(words: [0x4080_3C00, 0x9876_0000]))
        XCTAssertEqual(router.receive(off, from: "other").deliveries.map(\.message), [off])
        XCTAssertTrue(router.panic().isEmpty)
    }

    func testMIDI2SustainUsesFullValueAndPreservesOtherOwner() throws {
        var setup = session()
        setup.setup.ports.append(RouterPort(id: "other", name: "Other", direction: .input))
        setup.setup.routes.append(Route(source: "other", destination: "out"))
        var router = try Router(session: setup)
        let down = try XCTUnwrap(MIDIMessage(words: [0x40B0_4000, 0x8000_0001]))
        let up = try XCTUnwrap(MIDIMessage(words: [0x40B0_4000, 0x7FFF_FFFF]))
        XCTAssertEqual(router.receive(down, from: "in").deliveries.map(\.message), [down])
        _ = router.receive(down, from: "other")
        XCTAssertTrue(router.receive(up, from: "in").deliveries.isEmpty)
        XCTAssertEqual(router.disconnect(source: "other", timestamp: 123).map(\.message.words), [[0x40B0_4000, 0]])
        XCTAssertTrue(router.panic().isEmpty)
    }

    func testMergedInputChannelsKeepSeparateSustainOwners() throws {
        var setup = session()
        setup.setup.routes[0].channel = 1
        var router = try Router(session: setup)
        let down = try XCTUnwrap(MIDIMessage(words: [0x40B0_4000, 0x8000_0000]))
        let up = try XCTUnwrap(MIDIMessage(words: [0x40B0_4000, 0]))
        _ = router.receive(down, from: "in")
        _ = router.receive(down.replacing(channel: 2), from: "in")
        XCTAssertTrue(router.receive(up, from: "in").deliveries.isEmpty)
        XCTAssertEqual(router.receive(up.replacing(channel: 2), from: "in").deliveries.map(\.message), [up])
        XCTAssertTrue(router.panic().isEmpty)
    }

    func testPerNoteMessagesFollowTransposeAndConfigureFutureNotesAfterEdit() throws {
        for status: UInt32 in [0, 1, 6, 10, 15] {
            var setup = session()
            setup.setup.routes[0].transpose = 12
            setup.setup.routes[0].channel = 9
            var router = try Router(session: setup)
            let words: [UInt32] = [0x4000_3C00 | status << 20, status == 15 ? 0 : 0x1234_5678]
            let expression = try XCTUnwrap(MIDIMessage(words: words))
            let expected = [(words[0] & ~0x000F_FF00) | 0x0008_4800, words[1]]
            XCTAssertEqual(router.receive(expression, from: "in").deliveries.first?.message.words, expected)
            let note = try XCTUnwrap(MIDIMessage(words: [0x4090_3C00, 0xABCD_0000]))
            _ = router.receive(note, from: "in")
            XCTAssertEqual(router.receive(expression, from: "in").deliveries.first?.message.words, expected)
            setup.setup.routes[0].transpose = -12
            _ = try router.replaceSession(setup)
            XCTAssertEqual(router.receive(expression, from: "in").deliveries.first?.message.data1, 48)
            _ = router.receive(note, from: "in")
            let newPitch = router.receive(expression, from: "in").deliveries.first?.message
            XCTAssertEqual(newPitch?.data1, 48)
            XCTAssertEqual(newPitch?.words[1], words[1])
        }
    }

    func testPitchAttributeTransposesWithoutRoundingOrClamping() throws {
        var setup = session()
        setup.setup.routes[0].transpose = 12
        var router = try Router(session: setup)
        let pitch = try XCTUnwrap(MIDIMessage(words: [0x4090_3C03, 0x1234_7880]))
        XCTAssertEqual(router.receive(pitch, from: "in").deliveries.first?.message.words, [0x4090_4803, 0x1234_9080])
        let tooHigh = try XCTUnwrap(MIDIMessage(words: [0x4090_3D03, 0x1234_FFFF]))
        XCTAssertTrue(router.receive(tooHigh, from: "in").deliveries.isEmpty)
        let off = try XCTUnwrap(MIDIMessage(words: [0x4080_3D00, 0]))
        XCTAssertTrue(router.receive(off, from: "in").deliveries.isEmpty)
    }

    func testProgramChangeUsesMIDI2ProgramFieldAndPreservesUnmatchedBanks() throws {
        var setup = session()
        var alternative = setup.setup
        alternative.routes[0].transpose = 12
        let preset = Preset(name: "Octave", program: 92, setup: alternative)
        setup.presets = [preset]
        setup.programChangeSources = ["in"]
        var router = try Router(session: setup)
        _ = router.receive(try XCTUnwrap(MIDIMessage(words: [0x4090_3C00, 0xABCD_0000])), from: "in")
        let program = try XCTUnwrap(MIDIMessage(words: [0x40C0_0001, 0x5C00_0102]))
        let result = router.receive(program, from: "in")
        XCTAssertEqual(result.recalledPreset, preset.id)
        XCTAssertEqual(result.deliveries.map(\.message.words), [[0x4080_3C00, 0]])
        let unmatched = try XCTUnwrap(MIDIMessage(words: [0x40C0_0001, 0x5D00_0304]))
        XCTAssertEqual(router.receive(unmatched, from: "in").deliveries.map(\.message), [unmatched])
        setup.programChangeSources = []
        router = try Router(session: setup)
        XCTAssertEqual(router.receive(program, from: "in").deliveries.map(\.message), [program])
    }

    func testSlotsDoNotMultiplySysEx8MixedDataOrGroupFlexMessages() throws {
        var setup = session()
        let a = Slot(name: "A", channel: 1)
        let b = Slot(name: "B", channel: 2)
        setup.setup.ports[1].slots = [a, b]
        setup.setup.routes = [
            Route(source: "in", destination: "out", destinationSlot: a.id),
            Route(source: "in", destination: "out", destinationSlot: b.id),
        ]
        var router = try Router(session: setup)
        for words: [UInt32] in [
            [0x550E_7AFF, 0x80FE_FDFC, 0xFBFA_F9F8, 0xF7F6_F5F4],
            [0x5580_001E, 0x0001_0001, 0xDEF0_1234, 0x5678_9ABC],
            [0x5590_1234, 0x5678_9ABC, 0xDEF0_1234, 0x5678_9ABC],
            [0xD210_0000, 50_000_000, 0, 0],
        ] {
            let message = try XCTUnwrap(MIDIMessage(words: words, timestamp: 123))
            let deliveries = router.receive(message, from: "in").deliveries
            XCTAssertEqual(deliveries.count, 1)
            var expected = words
            if message.type == 5 && message.status >> 4 == 0 {
                XCTAssertEqual(message.data1, 0x7A)
                XCTAssertEqual(deliveries.first?.message.data1, 0)
                expected[0] &= ~0x0000_FF00
            }
            XCTAssertEqual(deliveries.first?.message.words, expected)
            XCTAssertEqual(deliveries.first?.message.timestamp, 123)
        }
        let orphan = try XCTUnwrap(MIDIMessage(words: [0x5590_1234, 0, 0, 0]))
        XCTAssertTrue(router.receive(orphan, from: "in").deliveries.isEmpty)
    }

    func testChannelAddressedFlexUsesSlotFilteringAndChannelRewrite() throws {
        var setup = session()
        let input = Slot(name: "Input", channel: 2)
        let output = Slot(name: "Output", channel: 9)
        setup.setup.ports[0].slots = [input]
        setup.setup.ports[1].slots = [output]
        setup.setup.routes[0].sourceSlot = input.id
        setup.setup.routes[0].destinationSlot = output.id
        var router = try Router(session: setup)
        let message = try XCTUnwrap(MIDIMessage(words: [0xD201_0101, 1, 2, 3]))
        XCTAssertEqual(message.channel, 2)
        XCTAssertEqual(router.receive(message, from: "in").deliveries.first?.message.words, [0xD208_0101, 1, 2, 3])
        XCTAssertTrue(router.receive(message.replacing(channel: 3), from: "in").deliveries.isEmpty)
    }

    func testLinkAndEndpointMessagesAreNotForwardedAcrossRoutes() throws {
        var router = try Router(session: session())
        for words: [UInt32] in [[0x0010_1234], [0x0020_1234], [0xF000_0101, 0, 0, 0]] {
            let message = try XCTUnwrap(MIDIMessage(words: words))
            let result = router.receive(message, from: "in")
            XCTAssertTrue(result.deliveries.isEmpty)
            XCTAssertNil(result.fault)
        }
    }
}
