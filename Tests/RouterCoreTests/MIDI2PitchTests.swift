import XCTest

@testable import RouterCore

final class MIDI2PitchTests: XCTestCase {
    private func session(transpose: Int = -12) -> Session {
        Session(
            setup: Setup(
                ports: [
                    RouterPort(id: "in", name: "Keys", direction: .input),
                    RouterPort(id: "out", name: "Synth", direction: .output),
                ], routes: [Route(source: "in", destination: "out", transpose: transpose)]))
    }

    private func message(_ header: UInt32, _ value: UInt32 = 0) throws -> MIDIMessage {
        try XCTUnwrap(MIDIMessage(words: [header, value]))
    }

    func testPitchAttributeAllowsRotatingIndexesOutsideThePitchRange() throws {
        var router = try Router(session: session())
        let on = try message(0x4090_0003, 0xABCD_7880)
        XCTAssertEqual(router.receive(on, from: "in").deliveries.map(\.message.words), [[0x4090_7403, 0xABCD_6080]])
        let pressure = try message(0x40A0_0000, 0x1234_5678)
        XCTAssertEqual(
            router.receive(pressure, from: "in").deliveries.map(\.message.words), [[0x40A0_7400, 0x1234_5678]])
        let off = try message(0x4080_0000, 0x9876_0000)
        XCTAssertEqual(router.receive(off, from: "in").deliveries.map(\.message.words), [[0x4080_7400, 0x9876_0000]])
    }

    func testRegisteredPerNotePitchKeepsFractionalPrecisionAndRestoresBeforeNoteOn() throws {
        var router = try Router(session: session())
        let pitch = try message(0x4000_0003, (60 << 25) | 123)
        let shifted: [UInt32] = [0x4000_7403, (48 << 25) | 123]
        XCTAssertEqual(router.receive(pitch, from: "in").deliveries.map(\.message.words), [shifted])
        let on = try message(0x4090_0000, 0xABCD_0000)
        XCTAssertEqual(
            router.receive(on, from: "in").deliveries.map(\.message.words), [shifted, [0x4090_7400, 0xABCD_0000]])
        let bend = try message(0x4000_0003, (61 << 25) | 456)
        XCTAssertEqual(
            router.receive(bend, from: "in").deliveries.map(\.message.words), [[0x4000_7403, (49 << 25) | 456]])
        XCTAssertEqual(router.panic().map(\.message.words), [[0x40F0_7403, 0], [0x4080_7400, 0]])
    }

    func testUnrepresentablePerNotePitchDoesNotStartOrReleaseAnotherNote() throws {
        var router = try Router(session: session())
        XCTAssertTrue(router.receive(try message(0x4000_0003, 123), from: "in").deliveries.isEmpty)
        XCTAssertTrue(router.receive(try message(0x4090_0000, 0xABCD_0000), from: "in").deliveries.isEmpty)
        XCTAssertTrue(router.receive(try message(0x4080_0000), from: "in").deliveries.isEmpty)
        XCTAssertTrue(router.panic().isEmpty)
    }

    func testRouteChangeRetainsInputPitchAndReplaysItForTheNewRoute() throws {
        var setup = session()
        var router = try Router(session: setup)
        _ = router.receive(try message(0x4000_0003, (60 << 25) | 123), from: "in")
        setup.setup.routes[0].transpose = 12
        _ = try router.replaceSession(setup)
        let notes = router.receive(try message(0x4090_0000, 0xABCD_0000), from: "in").deliveries
        XCTAssertEqual(notes.map(\.message.words), [[0x4000_0C03, (72 << 25) | 123], [0x4090_0C00, 0xABCD_0000]])
    }

    func testDetachDoesNotEndNotesAndResetAppliesOnlyToFutureNotes() throws {
        var router = try Router(session: session())
        _ = router.receive(try message(0x4000_0003, 60 << 25), from: "in")
        _ = router.receive(try message(0x4090_0000, 0xABCD_0000), from: "in")
        let management = router.receive(try message(0x40F0_0003), from: "in").deliveries
        XCTAssertEqual(management.map(\.message.words), [[0x40F0_7403, 0]])
        XCTAssertTrue(router.receive(try message(0x4090_0000, 0xABCD_0000), from: "in").deliveries.isEmpty)
        XCTAssertEqual(
            router.receive(try message(0x4080_0000), from: "in").deliveries.map(\.message.words), [[0x4080_7400, 0]])
        XCTAssertTrue(router.receive(try message(0x4080_0000), from: "in").deliveries.isEmpty)
    }

    func testResetWithoutDetachReleasesPitchThatBecomesOutOfRange() throws {
        var router = try Router(session: session())
        _ = router.receive(try message(0x4000_0003, 60 << 25), from: "in")
        _ = router.receive(try message(0x4090_0000, 0xABCD_0000), from: "in")
        let reset = router.receive(try message(0x40F0_0001), from: "in").deliveries
        XCTAssertEqual(reset.filter { $0.message.isNoteOff }.map(\.message.words), [[0x4080_7400, 0]])
        XCTAssertTrue(router.receive(try message(0x4080_0000), from: "in").deliveries.isEmpty)
        XCTAssertTrue(router.panic().isEmpty)
    }

    func testResetAllControllersDoesNotResetPerNotePitch() throws {
        var router = try Router(session: session())
        _ = router.receive(try message(0x4000_0003, 60 << 25), from: "in")
        _ = router.receive(try message(0x40B0_7900), from: "in")
        let result = router.receive(try message(0x4090_0000, 0xABCD_0000), from: "in")
        XCTAssertEqual(result.deliveries.last?.message.words, [0x4090_7400, 0xABCD_0000])
    }

    func testRouteChangeClearsPersistentPitchBeforeReusingOutputIndex() throws {
        var setup = session(transpose: 0)
        var router = try Router(session: setup)
        var destinationPitch: [UInt8: UInt32] = [:]
        var played: [UInt32] = []
        func apply(_ deliveries: [Delivery]) {
            for delivery in deliveries {
                let message = delivery.message
                if message.isPerNotePitch { destinationPitch[message.data1] = message.words[1] }
                if message.isPerNoteManagement && message.data2 & 1 != 0 { destinationPitch[message.data1] = nil }
                if message.isNoteOn { played.append(destinationPitch[message.data1] ?? UInt32(message.data1) << 25) }
            }
        }
        apply(router.receive(try message(0x4000_3C03, 72 << 25), from: "in").deliveries)
        setup.setup.routes[0].transpose = 12
        apply(try router.replaceSession(setup))
        apply(router.receive(try message(0x4090_3000, 0xABCD_0000), from: "in").deliveries)
        XCTAssertEqual(played, [60 << 25])
    }

    func testPerNoteCleanupWaitsForTheLastSourceOwner() throws {
        var setup = session(transpose: 0)
        setup.setup.ports.append(RouterPort(id: "other", name: "Other", direction: .input))
        setup.setup.routes.append(Route(source: "other", destination: "out"))
        var router = try Router(session: setup)
        _ = router.receive(try message(0x4000_3C03, 72 << 25), from: "in")
        _ = router.receive(try message(0x4010_3C01, 0x1234_5678), from: "other")
        XCTAssertTrue(router.disconnect(source: "in").isEmpty)
        XCTAssertEqual(router.disconnect(source: "other").map(\.message.words), [[0x40F0_3C03, 0]])
        XCTAssertTrue(router.panic().isEmpty)
    }

    func testDisconnectClearsPerNotePitchState() throws {
        var router = try Router(session: session())
        _ = router.receive(try message(0x4000_0003, 60 << 25), from: "in")
        _ = router.disconnect(source: "in")
        XCTAssertTrue(router.receive(try message(0x4090_0000, 0xABCD_0000), from: "in").deliveries.isEmpty)
    }
}
