import Foundation
import XCTest

@testable import RouterCore

final class RoutingTests: XCTestCase {
    func fixture() -> Session {
        Session(
            setup: Setup(
                ports: [
                    RouterPort(id: "in", name: "Keys", direction: .input),
                    RouterPort(id: "out", name: "Synth", direction: .output),
                ], routes: [Route(source: "in", destination: "out")]))
    }

    func testAllChannelMessagesPreserveOrRemapEveryChannel() throws {
        for channel in 0..<16 {
            for status in 0x8...0xE {
                var session = fixture()
                let event = try XCTUnwrap(
                    MIDIMessage(bytes: [UInt8(status << 4 | channel), 60, 64], timestamp: 123))
                var router = try Router(session: session)
                XCTAssertEqual(router.receive(event, from: "in").deliveries.first?.message, event)
                session.setup.routes[0].channel = 16
                router = try Router(session: session)
                let delivered = try XCTUnwrap(router.receive(event, from: "in").deliveries.first?.message)
                XCTAssertEqual(delivered.channel, 16)
                XCTAssertEqual(delivered.timestamp, 123)
                XCTAssertEqual(delivered.status, UInt8(status << 4 | 15))
            }
        }
    }

    func testSlotsFilterBeforeRewriteAndMainPortExcludesAssignedChannels() throws {
        var session = fixture()
        let input = Slot(name: "Lead", channel: 2)
        let output = Slot(name: "Layer", channel: 9)
        session.setup.ports[0].slots = [input]
        session.setup.ports[1].slots = [output]
        session.setup.routes[0].sourceSlot = input.id
        session.setup.routes[0].destinationSlot = output.id
        session.setup.routes[0].channel = 4
        var router = try Router(session: session)
        XCTAssertTrue(router.receive(.noteOn(60, channel: 1), from: "in").deliveries.isEmpty)
        XCTAssertEqual(
            router.receive(.noteOn(60, channel: 2), from: "in").deliveries.first?.message.channel, 9)
        session.setup.routes[0].sourceSlot = nil
        session.setup.routes[0].destinationSlot = nil
        session.setup.routes[0].channel = nil
        router = try Router(session: session)
        XCTAssertTrue(router.receive(.noteOn(60, channel: 2), from: "in").deliveries.isEmpty)
        XCTAssertTrue(router.receive(.noteOn(60, channel: 9), from: "in").deliveries.isEmpty)
        XCTAssertEqual(router.receive(.noteOn(60, channel: 3), from: "in").deliveries.count, 1)
    }

    func testLayeringDoesNotMultiplyClockOrSysEx() throws {
        var session = fixture()
        let a = Slot(name: "A", channel: 1)
        let b = Slot(name: "B", channel: 2)
        session.setup.ports[1].slots = [a, b]
        session.setup.routes = [
            Route(source: "in", destination: "out", destinationSlot: a.id),
            Route(source: "in", destination: "out", destinationSlot: b.id),
        ]
        var router = try Router(session: session)
        XCTAssertEqual(router.receive(.noteOn(60), from: "in").deliveries.count, 2)
        for words: [UInt32] in [[0x10F8_0000], [0x3012_7D01, 0]] {
            let message = try XCTUnwrap(MIDIMessage(words: words, timestamp: 987))
            let output = router.receive(message, from: "in").deliveries
            XCTAssertEqual(output.count, 1)
            XCTAssertEqual(output.first?.message, message)
        }
    }

    func testTransposeDropsOutOfRangeAndReleasesOldPitchOnEdit() throws {
        var session = fixture()
        session.setup.routes[0].transpose = 12
        var router = try Router(session: session)
        XCTAssertEqual(router.receive(.noteOn(60), from: "in").deliveries.first?.message.data1, 72)
        XCTAssertTrue(router.receive(.noteOn(120), from: "in").deliveries.isEmpty)
        session.setup.routes[0].transpose = -12
        let cleanup = try router.replaceSession(session)
        XCTAssertTrue(cleanup.contains { $0.message.isNoteOff && $0.message.data1 == 72 })
        XCTAssertTrue(router.receive(.noteOff(60), from: "in").deliveries.isEmpty)
        XCTAssertEqual(router.receive(.noteOn(60), from: "in").deliveries.first?.message.data1, 48)
    }

    func testVelocityZeroNoteOnReleasesAndPanicClearsSustain() throws {
        var router = try Router(session: fixture())
        _ = router.receive(.noteOn(60), from: "in")
        _ = router.receive(try XCTUnwrap(MIDIMessage(bytes: [0xB0, 64, 127])), from: "in")
        let off = router.receive(.noteOn(60, velocity: 0), from: "in").deliveries
        XCTAssertEqual(off.count, 1)
        XCTAssertTrue(off[0].message.isNoteOff)
        let cleanup = router.panic()
        XCTAssertTrue(cleanup.contains { $0.message.bytes == [0xB0, 64, 0] })
        XCTAssertTrue(router.panic().isEmpty)
    }

    func testPresetRecallConsumesOnlyAllowedMatchingProgramChange() throws {
        var session = fixture()
        var alternative = session.setup
        alternative.routes[0].transpose = 12
        let preset = Preset(name: "Octave", program: 7, setup: alternative)
        session.presets = [preset]
        session.programChangeSources = ["in"]
        var router = try Router(session: session)
        _ = router.receive(.noteOn(60), from: "in")
        let recalled = router.receive(try XCTUnwrap(MIDIMessage(bytes: [0xC0, 7])), from: "in")
        XCTAssertEqual(recalled.recalledPreset, preset.id)
        XCTAssertTrue(recalled.deliveries.contains { $0.message.isNoteOff })
        XCTAssertFalse(recalled.deliveries.contains { $0.message.status & 0xF0 == 0xC0 })
        XCTAssertEqual(router.receive(.noteOn(60), from: "in").deliveries.first?.message.data1, 72)
        XCTAssertEqual(
            router.receive(try XCTUnwrap(MIDIMessage(bytes: [0xC0, 8])), from: "in").deliveries.count, 1)
        session.programChangeSources = []
        router = try Router(session: session)
        XCTAssertNil(
            router.receive(try XCTUnwrap(MIDIMessage(bytes: [0xC0, 7])), from: "in").recalledPreset)
    }

    func testDisconnectReleasesOnlyTheSourcesOwnedNotes() throws {
        var session = fixture()
        session.setup.ports.append(RouterPort(id: "other", name: "Other", direction: .input))
        session.setup.routes.append(Route(source: "other", destination: "out"))
        var router = try Router(session: session)
        _ = router.receive(.noteOn(60), from: "in")
        _ = router.receive(.noteOn(64), from: "other")
        let cleanup = router.disconnect(source: "in")
        XCTAssertEqual(cleanup.filter { $0.message.isNoteOff }.map(\.message.data1), [60])
        XCTAssertEqual(router.receive(.noteOff(64), from: "other").deliveries.count, 1)
    }

    func testValidationRejectsInvalidRoutesSlotsAndPrograms() throws {
        var session = fixture()
        session.setup.routes[0].channel = 0
        XCTAssertThrowsError(try session.validate())
        session = fixture()
        session.setup.routes[0].destination = "missing"
        XCTAssertThrowsError(try session.validate())
        session = fixture()
        session.setup.ports[0].slots = [Slot(name: "A", channel: 1), Slot(name: "B", channel: 1)]
        XCTAssertThrowsError(try session.validate())
        session = fixture()
        session.presets = [
            Preset(name: "A", program: 0, setup: session.setup),
            Preset(name: "B", program: 0, setup: session.setup),
        ]
        XCTAssertThrowsError(try session.validate())
    }

    func testUnrelatedDiscoveryAndPortReorderingDoNotReleaseNotes() throws {
        var session = fixture()
        var router = try Router(session: session)
        _ = router.receive(.noteOn(60), from: "in")
        session.setup.ports.append(RouterPort(id: "new", name: "New", direction: .input))
        session.setup.ports.reverse()
        XCTAssertTrue(try router.replaceSession(session).isEmpty)
        XCTAssertEqual(router.receive(.noteOff(60), from: "in").deliveries.count, 1)
    }

    func testPresetRecallRetainsTriggerPortsMissingFromSavedSetup() throws {
        var session = fixture()
        session.presets = [Preset(name: "Empty", program: 1, setup: Setup())]
        session.programChangeSources = ["in"]
        var router = try Router(session: session)
        _ = router.receive(try XCTUnwrap(MIDIMessage(bytes: [0xC0, 1])), from: "in")
        XCTAssertNoThrow(try router.session.validate())
        XCTAssertNotNil(router.session.setup.port("in"))
    }

    func testRepeatedNoteOverflowIsBoundedAndReleasesHeldNotes() throws {
        var router = try Router(session: fixture())
        for _ in 0..<1024 { _ = router.receive(.noteOn(60), from: "in") }
        let result = router.receive(.noteOn(60), from: "in")
        XCTAssertNotNil(result.fault)
        XCTAssertTrue(result.deliveries.contains { $0.message.isNoteOff })
    }

    func testMalformedUMPIsRejected() {
        for words: [UInt32] in [[], [0x3090_0000], [0x3007_0000, 0], [0x3001_8000, 0], [0xFFFF_FFFF]] {
            XCTAssertNil(MIDIMessage(words: words))
        }
    }
}
