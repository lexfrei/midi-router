import Foundation
import XCTest

@testable import RouterCore

final class MultipartRoutingTests: XCTestCase {
    private func session() -> Session {
        Session(
            setup: Setup(
                ports: [
                    RouterPort(id: "a", name: "A", direction: .input),
                    RouterPort(id: "b", name: "B", direction: .input),
                    RouterPort(id: "out", name: "Output", direction: .output),
                    RouterPort(id: "next", name: "Next", direction: .output),
                ], routes: [Route(source: "a", destination: "out"), Route(source: "b", destination: "out")]))
    }

    private func sysex(_ form: UInt32, _ byte: UInt32, group: UInt32 = 0) -> MIDIMessage {
        MIDIMessage(words: [0x3001_0000 | group << 24 | form << 20 | byte << 8, 0])!
    }

    private func received(_ deliveries: [Delivery]) -> [[UInt8]] {
        var active: [UInt8]?
        var messages: [[UInt8]] = []
        for delivery in deliveries {
            let message = delivery.message
            if message.type == 1 && message.status >= 0xF8 { continue }
            guard message.type == 3 else {
                active = nil
                continue
            }
            switch (message.words[0] >> 20) & 15 {
            case 0:
                messages.append(message.bytes)
                active = nil
            case 1: active = message.bytes
            case 2: active?.append(contentsOf: message.bytes)
            case 3:
                if var bytes = active {
                    bytes += message.bytes
                    messages.append(bytes)
                }
                active = nil
            default: break
            }
        }
        return messages
    }

    func testConcurrentSysExCannotMixReceivingMessages() throws {
        var router = try Router(session: session())
        var deliveries = router.receive(sysex(1, 1), from: "a").deliveries
        deliveries += router.receive(sysex(1, 2), from: "b").deliveries
        deliveries += router.receive(sysex(3, 3), from: "a").deliveries
        deliveries += router.receive(sysex(3, 4), from: "b").deliveries
        XCTAssertEqual(received(deliveries), [[1, 3]])
    }

    func testRouteChangesKeepAdmittedDestination() throws {
        var configuration = session()
        var router = try Router(session: configuration)
        var deliveries = router.receive(sysex(1, 1), from: "a").deliveries
        configuration.setup.routes[0].destination = "next"
        deliveries += try router.replaceSession(configuration)
        deliveries += router.receive(sysex(3, 2), from: "a").deliveries
        XCTAssertEqual(Set(deliveries.map(\.destination)), ["out"])
        XCTAssertEqual(received(deliveries), [[1, 2]])
    }

    func testRealtimeAndUnrelatedGroupsDoNotBreakTransfers() throws {
        var router = try Router(session: session())
        var deliveries = router.receive(sysex(1, 1), from: "a").deliveries
        XCTAssertEqual(router.receive(MIDIMessage(words: [0x10F8_0000])!, from: "b").deliveries.count, 1)
        XCTAssertEqual(router.receive(sysex(0, 5, group: 1), from: "b").deliveries.count, 1)
        deliveries += router.receive(sysex(3, 2), from: "a").deliveries
        XCTAssertEqual(received(deliveries), [[1, 2]])
    }

    private func eight(_ form: UInt32, id: UInt32 = 0) -> MIDIMessage {
        MIDIMessage(words: [0x5002_007D | form << 20 | id << 8, 0, 0, 0])!
    }

    private func header(id: UInt32 = 0, chunk: UInt32 = 1, total: UInt32 = 1) -> MIDIMessage {
        MIDIMessage(words: [0x5080_001E | id << 16, total << 16 | chunk, 0x007D_0000, 0])!
    }

    func testSysEx8ContentionIsNonfatalAndSourceLossAbortsReceiver() throws {
        var router = try Router(session: session())
        XCTAssertEqual(router.receive(eight(1), from: "a").deliveries.count, 1)
        XCTAssertTrue(router.receive(eight(1), from: "b").deliveries.isEmpty)
        XCTAssertTrue(router.receive(eight(3), from: "b").deliveries.isEmpty)
        let cleanup = router.disconnect(source: "a")
        XCTAssertEqual(cleanup.count, 1)
        XCTAssertEqual(cleanup.first?.message.words[0], 0x503F_0000)
        XCTAssertTrue(router.receive(eight(3), from: "a").deliveries.isEmpty)
        XCTAssertEqual(router.receive(eight(1), from: "b").deliveries.count, 1)
    }

    func testMDSCollisionRemapsWholeReceivingStreamsAndReleasesIDs() throws {
        var router = try Router(session: session())
        let a = router.receive(header(), from: "a").deliveries
        let b = router.receive(header(), from: "b").deliveries
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
        XCTAssertNotEqual(a.first?.message.status, b.first?.message.status)
        let payload = MIDIMessage(words: [0x5090_1111, 0x2222_2222, 0x3333_3333, 0x4444_4444])!
        XCTAssertEqual(router.receive(payload, from: "a").deliveries.first?.message.status, 0x90)
        XCTAssertEqual(router.receive(payload, from: "b").deliveries.first?.message.status, 0x91)
        XCTAssertTrue(router.receive(payload, from: "b").deliveries.isEmpty)
        XCTAssertEqual(router.receive(header(), from: "b").deliveries.first?.message.status, 0x80)
    }

    func testFlexChannelMappingAnchorsAndFlushesAsOneMessage() throws {
        var configuration = session()
        configuration.setup.routes[0].channel = 4
        var router = try Router(session: configuration)
        let start = MIDIMessage(words: [0xD040_0100, 1, 2, 3])!
        let end = MIDIMessage(words: [0xD0C0_0100, 4, 5, 6])!
        XCTAssertTrue(router.receive(start, from: "a").deliveries.isEmpty)
        configuration.setup.routes[0].channel = 8
        _ = try router.replaceSession(configuration)
        let output = router.receive(end, from: "a").deliveries
        XCTAssertEqual(output.count, 2)
        XCTAssertEqual(output.map(\.message.channel), [4, 4])
    }

    func testLargeSysExStreamsWithoutAccumulationOrSmallPayloadLimit() throws {
        var router = try Router(session: session())
        XCTAssertEqual(router.receive(sysex(1, 1), from: "a").deliveries.count, 1)
        for _ in 0..<20_000 {
            XCTAssertEqual(router.receive(sysex(2, 2), from: "a").deliveries.count, 1)
        }
        XCTAssertEqual(router.receive(sysex(3, 3), from: "a").deliveries.count, 1)
        XCTAssertEqual(router.receive(.noteOn(60), from: "a").deliveries.count, 1)
    }

    func testSourceInterruptionDropsStreamingTailButNotNotes() throws {
        var router = try Router(session: session())
        _ = router.receive(sysex(1, 1), from: "a")
        let note = router.receive(.noteOn(60), from: "a")
        XCTAssertEqual(note.deliveries.count, 1)
        XCTAssertFalse(note.diagnostics.isEmpty)
        XCTAssertNil(note.fault)
        XCTAssertTrue(router.receive(sysex(3, 2), from: "a").deliveries.isEmpty)
    }

    func testResourceAndIdleBoundsAreIndependentOfMusicalEvents() throws {
        var state = MultipartRouting()
        let candidate = Delivery(destination: "out", message: sysex(1, 1))
        for source in 0..<128 {
            let target = Delivery(destination: String(source), message: candidate.message)
            XCTAssertEqual(
                state.receive(
                    sysex(1, 1), source: String(source), candidates: [target], now: 0, canDeliver: { _ in true }
                ).count, 1)
        }
        _ = state.receive(sysex(1, 1), source: "overflow", candidates: [candidate], now: 0, canDeliver: { _ in true })
        XCTAssertTrue(
            state.receive(sysex(3, 2), source: "overflow", candidates: [candidate], now: 1, canDeliver: { _ in true })
                .isEmpty)
        XCTAssertEqual(
            state.receive(sysex(3, 2), source: "0", candidates: [], now: 29, canDeliver: { _ in true }).count, 1)
        XCTAssertTrue(state.expire(now: 30, timestamp: 0).isEmpty)
        XCTAssertTrue(
            state.receive(sysex(3, 2), source: "1", candidates: [], now: 31, canDeliver: { _ in true }).isEmpty)
        for _ in 0..<1000 {
            _ = state.receive(sysex(3, 2), source: "missing", candidates: [], now: 31, canDeliver: { _ in true })
        }
        XCTAssertLessThanOrEqual(state.diagnostics.count, 128)
        XCTAssertFalse(state.diagnostics.isEmpty)
    }

    func testDestinationLossAndAvailabilityCannotReadmitTail() throws {
        var router = try Router(session: session())
        _ = router.receive(sysex(1, 1), from: "a")
        router.disconnect(destination: "out")
        XCTAssertFalse(router.takeDiagnostics().isEmpty)
        XCTAssertTrue(router.receive(sysex(3, 2), from: "a").deliveries.isEmpty)
        _ = router.receive(sysex(1, 3), from: "a")
        XCTAssertTrue(router.receive(sysex(2, 4), from: "a", canDeliver: { _ in false }).deliveries.isEmpty)
        XCTAssertTrue(router.receive(sysex(3, 5), from: "a").deliveries.isEmpty)
        XCTAssertEqual(received(router.receive(sysex(0, 6), from: "a").deliveries), [[6]])
    }

    func testCleanupInterruptsSysExWithoutDeliveringStaleTail() throws {
        var router = try Router(session: session())
        _ = router.receive(.noteOn(60), from: "b")
        var deliveries = router.receive(sysex(1, 1), from: "a").deliveries
        deliveries += router.disconnect(source: "b")
        XCTAssertFalse(router.takeDiagnostics().isEmpty)
        deliveries += router.receive(sysex(3, 2), from: "a").deliveries
        XCTAssertTrue(deliveries.contains { $0.message.isNoteOff })
        XCTAssertEqual(received(deliveries), [])
        _ = router.receive(sysex(1, 3), from: "a")
        XCTAssertTrue(router.panic().isEmpty)
        XCTAssertFalse(router.takeDiagnostics().isEmpty)
        XCTAssertTrue(router.receive(sysex(3, 4), from: "a").deliveries.isEmpty)
    }

    private func receivedEight(_ deliveries: [Delivery]) -> [[UInt8]] {
        var active: [UInt8: [UInt8]] = [:]
        var messages: [[UInt8]] = []
        for delivery in deliveries where delivery.message.type == 5 {
            let message = delivery.message
            let form = message.status >> 4
            guard form <= 3 else { continue }
            let id = message.data1
            if form == 3 && message.status & 15 == 15 {
                active[id] = nil
                continue
            }
            let raw =
                [message.data2]
                + message.words.dropFirst().flatMap { word in
                    (0..<4).map { UInt8((word >> (24 - $0 * 8)) & 255) }
                }
            let bytes = Array(raw.prefix(Int(message.status & 15) - 1))
            if form == 0 { messages.append(bytes) }
            if form == 1 { active[id] = bytes }
            if form == 2 { active[id]?.append(contentsOf: bytes) }
            if form == 3, var complete = active.removeValue(forKey: id) {
                complete += bytes
                messages.append(complete)
            }
        }
        XCTAssertTrue(active.isEmpty, "The receiver must not retain an incomplete SysEx8 stream.")
        return messages
    }

    func testSysEx8ReceiverSeesAbortInsteadOfSuccessfulPartialMessage() throws {
        var router = try Router(session: session())
        var output = router.receive(eight(1, id: 77), from: "a").deliveries
        let collision = router.receive(eight(1, id: 77), from: "b")
        XCTAssertFalse(collision.diagnostics.isEmpty)
        XCTAssertNil(collision.fault)
        output += collision.deliveries
        output += router.receive(eight(3, id: 77), from: "b").deliveries
        output += router.disconnect(source: "a")
        XCTAssertEqual(receivedEight(output), [])
        output = router.receive(eight(1, id: 88), from: "b").deliveries
        output += router.receive(eight(3, id: 88), from: "b").deliveries
        XCTAssertEqual(receivedEight(output), [[0x7D, 0x7D]])
    }

    private func receivedMDS(_ deliveries: [Delivery]) -> [[UInt32]] {
        var active: [UInt8: [UInt32]] = [:]
        var final: Set<UInt8> = []
        var messages: [[UInt32]] = []
        for delivery in deliveries where delivery.message.type == 5 {
            let message = delivery.message
            let id = message.status & 15
            if message.status >> 4 == 8 {
                let chunk = message.words[1] & 0xFFFF
                if chunk == 0 {
                    active[id] = nil
                    continue
                }
                if chunk == 1 { active[id] = [] }
                if chunk == message.words[1] >> 16 { final.insert(id) }
            } else if message.status >> 4 == 9 {
                active[id]?.append(message.words[0] & 0xFFFF)
                if final.remove(id) != nil, let complete = active.removeValue(forKey: id) { messages.append(complete) }
            }
        }
        XCTAssertTrue(active.isEmpty, "The receiver must not retain an incomplete MDS.")
        return messages
    }

    func testMDSReceiverReassemblesConcurrentMultiChunkTransfersAcrossRouteEdit() throws {
        var configuration = session()
        var router = try Router(session: configuration)
        func payload(_ value: UInt32) -> MIDIMessage { MIDIMessage(words: [0x5090_0000 | value, 0, 0, 0])! }
        var output = router.receive(header(total: 2), from: "a").deliveries
        output += router.receive(header(total: 2), from: "b").deliveries
        output += router.receive(payload(0xAA), from: "a").deliveries
        output += router.receive(payload(0xBB), from: "b").deliveries
        configuration.setup.routes[0].destination = "next"
        _ = try router.replaceSession(configuration)
        output += router.receive(header(chunk: 2, total: 2), from: "a").deliveries
        output += router.receive(header(chunk: 2, total: 2), from: "b").deliveries
        output += router.receive(payload(0xCC), from: "a").deliveries
        output += router.receive(payload(0xDD), from: "b").deliveries
        XCTAssertEqual(Set(output.map(\.destination)), ["out"])
        XCTAssertEqual(receivedMDS(output), [[0xAA, 0xCC], [0xBB, 0xDD]])
    }

    func testSourceAndDestinationRemovalInSessionCannotRetainTransfers() throws {
        var configuration = session()
        var router = try Router(session: configuration)
        var output = router.receive(eight(1), from: "a").deliveries
        configuration.setup.routes.removeAll { $0.source == "a" }
        configuration.setup.ports.removeAll { $0.id == "a" }
        output += try router.replaceSession(configuration)
        XCTAssertEqual(receivedEight(output), [])
        XCTAssertFalse(router.takeDiagnostics().isEmpty)
        XCTAssertTrue(router.receive(eight(3), from: "a").deliveries.isEmpty)
    }

    func testUnknownSysEx7StatusStaysOpaque() throws {
        var router = try Router(session: session())
        let opaque = MIDIMessage(words: [0x307F_1234, 0xFFFF_FFFF])!
        XCTAssertEqual(router.receive(opaque, from: "a").deliveries.map(\.message), [opaque])
    }

    func testFanOutRetainsOnlyAdmittedAvailableDestinations() throws {
        var configuration = session()
        configuration.setup.routes.append(Route(source: "b", destination: "next"))
        var router = try Router(session: configuration)
        var output = router.receive(sysex(1, 1), from: "a").deliveries
        let competing = router.receive(sysex(1, 2), from: "b")
        XCTAssertEqual(competing.deliveries.map(\.destination), ["next"])
        XCTAssertFalse(competing.diagnostics.isEmpty)
        output += competing.deliveries
        output += router.receive(sysex(3, 3), from: "a").deliveries
        output += router.receive(sysex(3, 4), from: "b").deliveries
        XCTAssertEqual(received(output.filter { $0.destination == "out" }), [[1, 3]])
        XCTAssertEqual(received(output.filter { $0.destination == "next" }), [[2, 4]])
        let start = router.receive(sysex(1, 5), from: "b", canDeliver: { $0 == "next" })
        let end = router.receive(sysex(3, 6), from: "b")
        XCTAssertEqual(Set((start.deliveries + end.deliveries).map(\.destination)), ["next"])
    }

    func testRouteCleanupImmediatelyReleasesNoteOffAndInterruptsOnlyItsOutput() throws {
        var configuration = session()
        var router = try Router(session: configuration)
        _ = router.receive(.noteOn(60), from: "b")
        _ = router.receive(sysex(1, 1), from: "a")
        configuration.setup.routes[1].transpose = 12
        let cleanup = try router.replaceSession(configuration)
        XCTAssertEqual(cleanup.filter { $0.message.isNoteOff }.count, 1)
        XCTAssertFalse(router.takeDiagnostics().isEmpty)
        XCTAssertTrue(router.receive(sysex(3, 2), from: "a").deliveries.isEmpty)
    }

    func testFlexReceiverGetsContiguousBoundedMessagesWhileNotesRemainLive() throws {
        var router = try Router(session: session())
        let start = MIDIMessage(words: [0xD050_0100, 1, 2, 3])!
        let middle = MIDIMessage(words: [0xD090_0100, 4, 5, 6])!
        let end = MIDIMessage(words: [0xD0D0_0100, 7, 8, 9])!
        _ = router.receive(.noteOn(60), from: "b")
        XCTAssertTrue(router.receive(start, from: "a").deliveries.isEmpty)
        XCTAssertFalse(router.receive(start, from: "b").diagnostics.isEmpty)
        XCTAssertEqual(router.receive(.noteOff(60), from: "b").deliveries.filter { $0.message.isNoteOff }.count, 1)
        for _ in 0..<30 { XCTAssertTrue(router.receive(middle, from: "a").deliveries.isEmpty) }
        let delivered = router.receive(end, from: "a").deliveries.map(\.message)
        XCTAssertEqual(delivered.count, 32)
        XCTAssertEqual(
            delivered.flatMap { $0.words.dropFirst() },
            [1, 2, 3] + Array(repeating: [UInt32(4), 5, 6], count: 30).flatMap { $0 } + [7, 8, 9])
        _ = router.receive(start, from: "a")
        for _ in 0..<30 { _ = router.receive(middle, from: "a") }
        let overflow = router.receive(middle, from: "a")
        XCTAssertTrue(overflow.deliveries.isEmpty)
        XCTAssertFalse(overflow.diagnostics.isEmpty)
        XCTAssertTrue(router.receive(end, from: "a").deliveries.isEmpty)
    }

    func testMDSIDsAreBoundedAndIndependentAcrossGroups() throws {
        var state = MultipartRouting()
        let candidate = Delivery(destination: "out", message: header())
        for source in 0..<16 {
            let output = state.receive(
                header(), source: String(source), candidates: [candidate], now: 0, canDeliver: { _ in true })
            XCTAssertEqual(output.first?.message.status, 0x80 | UInt8(source))
        }
        XCTAssertTrue(
            state.receive(header(), source: "overflow", candidates: [candidate], now: 0, canDeliver: { _ in true })
                .isEmpty)
        var other = header().words
        other[0] |= 1 << 24
        XCTAssertEqual(
            state.receive(
                MIDIMessage(words: other)!, source: "overflow", candidates: [candidate], now: 0,
                canDeliver: { _ in true }
            ).first?.message.status, 0x80)
        let payload = MIDIMessage(words: [0x5090_0000, 0, 0, 0])!
        _ = state.receive(payload, source: "0", candidates: [], now: 0, canDeliver: { _ in true })
        XCTAssertEqual(
            state.receive(header(), source: "overflow", candidates: [candidate], now: 0, canDeliver: { _ in true })
                .first?.message.status, 0x80)
    }

    func testPanicAndReconnectAbortNativeStreams() throws {
        var router = try Router(session: session())
        var output = router.receive(eight(1), from: "a").deliveries
        output += router.reconnect(source: "a")
        XCTAssertEqual(receivedEight(output), [])
        XCTAssertTrue(router.receive(eight(3), from: "a").deliveries.isEmpty)
        output = router.receive(eight(1), from: "a").deliveries
        output += router.panic()
        XCTAssertEqual(receivedEight(output), [])
        output = router.receive(header(total: 0), from: "b").deliveries
        output += router.disconnect(source: "b")
        XCTAssertEqual(receivedMDS(output), [])
    }

    func testIdleTimeoutAbortsSysEx8AndOpaqueTypesDoNotAcquireGroupSemantics() throws {
        var state = MultipartRouting()
        let start = eight(1)
        var output = state.receive(
            start, source: "a", candidates: [Delivery(destination: "out", message: start)], now: 0,
            canDeliver: { _ in true })
        XCTAssertTrue(state.expire(now: 29, timestamp: 1).isEmpty)
        output += state.expire(now: 30, timestamp: 2)
        XCTAssertEqual(receivedEight(output), [])
        XCTAssertEqual(output.last?.message.timestamp, 2)
        XCTAssertTrue(state.receive(eight(3), source: "a", candidates: [], now: 31, canDeliver: { _ in true }).isEmpty)
        var router = try Router(session: session())
        _ = router.receive(sysex(1, 1), from: "a")
        for words: [UInt32] in [[0x6090_3C00], [0x8090_3C00, 123], [0xE090_3C00, 123, 456, 789]] {
            let unknown = MIDIMessage(words: words)!
            XCTAssertNil(unknown.groupNumber)
            XCTAssertEqual(router.receive(unknown, from: "b").deliveries.map(\.message), [unknown])
        }
        XCTAssertEqual(router.receive(sysex(3, 2), from: "a").deliveries.count, 1)
    }

    func testRemovingAllSessionPortsAbortsStillReachableNativeReceivers() throws {
        var router = try Router(session: session())
        var output = router.receive(eight(1), from: "a").deliveries
        let cleanup = try router.replaceSession(Session(setup: Setup()))
        XCTAssertEqual(cleanup.map(\.destination), ["out"])
        output += cleanup
        XCTAssertEqual(receivedEight(output), [])
        XCTAssertTrue(router.receive(eight(3), from: "a").deliveries.isEmpty)

        router = try Router(session: session())
        output = router.receive(header(total: 0), from: "a").deliveries
        output += try router.replaceSession(Session(setup: Setup()))
        XCTAssertEqual(receivedMDS(output), [])
    }

    func testRetiringOneSessionOutputAbortsOnlyThatFanOutTarget() throws {
        var configuration = session()
        configuration.setup.routes.append(Route(source: "a", destination: "next"))
        var router = try Router(session: configuration)
        var output = router.receive(eight(1), from: "a").deliveries
        configuration.setup.routes.removeAll { $0.destination == "out" }
        configuration.setup.ports.removeAll { $0.id == "out" }
        let cleanup = try router.replaceSession(configuration)
        XCTAssertEqual(cleanup.map(\.destination), ["out"])
        output += cleanup
        let end = router.receive(eight(3), from: "a").deliveries
        XCTAssertEqual(end.map(\.destination), ["next"])
        output += end
        XCTAssertEqual(receivedEight(output.filter { $0.destination == "out" }), [])
        XCTAssertEqual(receivedEight(output.filter { $0.destination == "next" }), [[0x7D, 0x7D]])
    }

}
