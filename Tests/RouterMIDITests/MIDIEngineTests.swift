import CoreMIDI
import Foundation
import RouterCore
import XCTest

@testable import RouterMIDI

private final class Receiver: @unchecked Sendable {
    let condition = NSCondition()
    var messages: [MIDIMessage] = []
    func receive(_ list: UnsafePointer<MIDIEventList>) {
        let values = decodeEventList(list)
        condition.lock()
        messages.append(contentsOf: values)
        condition.broadcast()
        condition.unlock()
    }
    func waitFor(_ count: Int) -> [MIDIMessage] {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while messages.count < count && condition.wait(until: deadline) {}
        return messages
    }
}

private final class VirtualFixture {
    var client = MIDIClientRef()
    var source = MIDIEndpointRef()
    var destination = MIDIEndpointRef()
    let receiver = Receiver()
    let name = "Router Test \(UUID().uuidString)"
    init(midiProtocol: MIDIProtocolID = ._1_0) throws {
        try midiCheck(MIDIClientCreateWithBlock(name as CFString, &client, nil), "Create fixture client")
        do {
            try midiCheck(
                MIDISourceCreateWithProtocol(client, "\(name) Source" as CFString, midiProtocol, &source),
                "Create fixture source")
            try midiCheck(MIDIObjectSetIntegerProperty(source, kMIDIPropertyPrivate, 1), "Hide fixture source")
            let receiver = receiver
            try midiCheck(
                MIDIDestinationCreateWithProtocol(client, "\(name) Destination" as CFString, midiProtocol, &destination)
                {
                    list, _ in receiver.receive(list)
                }, "Create fixture destination")
            try midiCheck(
                MIDIObjectSetIntegerProperty(destination, kMIDIPropertyPrivate, 1), "Hide fixture destination")
        } catch {
            MIDIClientDispose(client)
            throw error
        }
    }
    deinit { MIDIClientDispose(client) }
    var inputID: String {
        var id: Int32 = 0
        MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id)
        return MIDIEngine.endpointID(uniqueID: id, direction: .input)
    }
    var outputID: String {
        var id: Int32 = 0
        MIDIObjectGetIntegerProperty(destination, kMIDIPropertyUniqueID, &id)
        return MIDIEngine.endpointID(uniqueID: id, direction: .output)
    }
    func send(_ messages: [MIDIMessage]) throws {
        for message in messages {
            try withEventList(
                message.replacing(timestamp: message.timestamp == 0 ? mach_absolute_time() : message.timestamp)
            ) {
                try midiCheck(MIDIReceivedEventList(source, $0), "Publish fixture event")
            }
        }
    }
}

final class MIDIEngineTests: XCTestCase {
    func testCompetingTransfersReportDiagnosticsWithoutSuspendingMusic() throws {
        let first = try VirtualFixture(midiProtocol: ._2_0)
        let second = try VirtualFixture(midiProtocol: ._2_0)
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Contention \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [first.source, second.source], destinations: [first.destination])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [
            Route(source: first.inputID, destination: first.outputID),
            Route(source: second.inputID, destination: first.outputID),
        ]
        try engine.update(session: session)
        let startA = try XCTUnwrap(MIDIMessage(words: [0x3012_7D01, 0]))
        let startB = try XCTUnwrap(MIDIMessage(words: [0x3012_7D02, 0]))
        let endA = try XCTUnwrap(MIDIMessage(words: [0x3031_0300, 0]))
        let endB = try XCTUnwrap(MIDIMessage(words: [0x3031_0400, 0]))
        let clock = try XCTUnwrap(MIDIMessage(words: [0x10F8_0000]))
        let on = try XCTUnwrap(MIDIMessage(words: [0x4090_3C00, 0xABCD_0000]))
        let off = try XCTUnwrap(MIDIMessage(words: [0x4080_3C00, 0]))
        try first.send([startA])
        XCTAssertEqual(first.receiver.waitFor(1).count, 1)
        try second.send([startB, clock])
        XCTAssertEqual(first.receiver.waitFor(2).last?.words, clock.words)
        try first.send([endA])
        XCTAssertEqual(first.receiver.waitFor(3).last?.words, endA.words)
        try second.send([endB, on, off])
        XCTAssertEqual(
            first.receiver.waitFor(5).map(\.words), [startA.words, clock.words, endA.words, on.words, off.words])
        let snapshot = engine.snapshot()
        XCTAssertNil(snapshot.fault)
        XCTAssertTrue(snapshot.diagnostics.contains { $0.contains("SysEx7") })
        XCTAssertTrue(engine.snapshot().diagnostics.isEmpty)
    }

    func testSysEx8AbortDoesNotSuspendSubsequentMusic() throws {
        let start = try XCTUnwrap(MIDIMessage(words: [0x5512_7AFF, 0, 0, 0]))
        let abort = try XCTUnwrap(MIDIMessage(words: [0x553F_7A00, 0, 0, 0]))
        let on = try XCTUnwrap(MIDIMessage(words: [0x4591_3C00, 0xABCD_0000]))
        let off = try XCTUnwrap(MIDIMessage(words: [0x4581_3C00, 0x9876_0000]))
        let fixture = try VirtualFixture(midiProtocol: ._2_0)
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Abort \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [Route(source: fixture.inputID, destination: fixture.outputID)]
        try engine.update(session: session)
        try fixture.send([start, abort, on, off])
        let received = fixture.receiver.waitFor(4)
        XCTAssertEqual(received.count, 4)
        guard received.count == 4 else { return }
        let streamMask = ~UInt32(0x0000_FF00)
        XCTAssertEqual(received[0].words[0] & streamMask, start.words[0] & streamMask)
        XCTAssertEqual(received[1].words[0] & streamMask, abort.words[0] & streamMask)
        XCTAssertEqual(received[0].data1, received[1].data1)
        XCTAssertEqual(Array(received[1].words.dropFirst()), [0, 0, 0])
        XCTAssertEqual(received.suffix(2).map(\.words), [on.words, off.words])
        XCTAssertNil(engine.snapshot().fault)
    }

    func testReservedNoteBitsDoNotSplitOwnershipAcrossRouteEdits() throws {
        let on = try XCTUnwrap(MIDIMessage(words: [0x4591_BC01, 0xABCD_1234]))
        let off = try XCTUnwrap(MIDIMessage(words: [0x4581_3C02, 0x9876_4321]))
        let marker = try XCTUnwrap(MIDIMessage(words: [0x45B1_0100, 0x1234_5678]))
        let fixture = try VirtualFixture(midiProtocol: ._2_0)
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Reserved Bits \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [
            Route(source: fixture.inputID, destination: fixture.outputID, channel: 9, transpose: 12)
        ]
        try engine.update(session: session)
        try fixture.send([on])
        XCTAssertEqual(fixture.receiver.waitFor(1).first?.words, [0x4598_C801, 0xABCD_1234])
        session.setup.routes[0].transpose = -12
        try engine.update(session: session)
        XCTAssertEqual(fixture.receiver.waitFor(2).last?.words, [0x4588_C800, 0])
        try fixture.send([off, marker])
        let received = fixture.receiver.waitFor(3)
        XCTAssertEqual(received.count, 3)
        XCTAssertEqual(received.last?.words, [0x45B8_0100, 0x1234_5678])
        XCTAssertNil(engine.snapshot().fault)
    }

    func testPrivateMIDI2PortsPreserveValuesGroupsAndSysEx8() throws {
        let fixture = try VirtualFixture(midiProtocol: ._2_0)
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router MIDI 2 \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.start()
        var session = engine.snapshot().session
        XCTAssertNotNil(session.setup.port(fixture.inputID))
        session.setup.routes = [
            Route(source: fixture.inputID, destination: fixture.outputID, channel: 9, transpose: 12)
        ]
        try engine.update(session: session)
        for endpoint in [engine.nativeEndpoints().input, engine.nativeEndpoints().output] {
            var isPrivate: Int32 = 0
            try midiCheck(MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyPrivate, &isPrivate), "Read privacy")
            XCTAssertEqual(isPrivate, 1)
            var midiProtocol: Int32 = 0
            try midiCheck(
                MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyProtocolID, &midiProtocol), "Read protocol")
            XCTAssertEqual(midiProtocol, 2)
        }
        let timestamp = mach_absolute_time()
        let raw: [[UInt32]] = [
            [0x4591_3C00, 0xABCD_0000], [0x4501_3C01, 0x1234_5678],
            [0x4561_3C00, 0x8765_4321], [0x45B1_0100, 0x1234_5678],
            [0x45C1_0001, 0x5C00_0102], [0x550E_7AFF, 0x80FE_FDFC, 0xFBFA_F9F8, 0xF7F6_F5F4],
            [0x5580_001E, 0x0001_0001, 0x007D_0001, 0], [0x5590_0102, 0x0304_0506, 0x0708_090A, 0x0B0C_0D0E],
            [0xD510_0000, 50_000_000, 0, 0],
            [0x4581_3C00, 0x9876_0000],
        ]
        let messages = try raw.map { try XCTUnwrap(MIDIMessage(words: $0, timestamp: timestamp)) }
        try fixture.send(messages)
        let delivered = fixture.receiver.waitFor(messages.count)
        XCTAssertEqual(
            delivered.map(\.words),
            [
                [0x4598_4800, 0xABCD_0000], [0x4508_4801, 0x1234_5678],
                [0x4568_4800, 0x8765_4321], [0x45B8_0100, 0x1234_5678],
                [0x45C8_0001, 0x5C00_0102], [0x550E_00FF, 0x80FE_FDFC, 0xFBFA_F9F8, 0xF7F6_F5F4],
                raw[6], raw[7], raw[8], [0x4588_4800, 0x9876_0000],
            ])
        XCTAssertTrue(delivered.allSatisfy { $0.timestamp == timestamp })
        XCTAssertNil(engine.snapshot().fault)
    }

    func testMIDI2VirtualInputAndOutputDoNotQuantizeDAWTraffic() throws {
        let fixture = try VirtualFixture(midiProtocol: ._2_0)
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router DAW 2 \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [], destinations: [])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [Route(source: MIDIEngine.virtualInputID, destination: MIDIEngine.virtualOutputID)]
        try engine.update(session: session)
        var output = MIDIPortRef()
        var input = MIDIPortRef()
        let receiver = fixture.receiver
        try midiCheck(MIDIOutputPortCreate(fixture.client, "DAW Send" as CFString, &output), "Create DAW output")
        try midiCheck(
            MIDIInputPortCreateWithProtocol(fixture.client, "DAW Receive" as CFString, ._2_0, &input) { list, _ in
                receiver.receive(list)
            }, "Create DAW input")
        let endpoints = engine.nativeEndpoints()
        try midiCheck(MIDIPortConnectSource(input, endpoints.output, nil), "Subscribe DAW")
        let words: [[UInt32]] = [[0x46B3_0100, 0x1234_5678], [0x46E3_0000, 0x8765_4321]]
        let messages = try words.map {
            try XCTUnwrap(MIDIMessage(words: $0, timestamp: mach_absolute_time()))
        }
        for message in messages {
            try withEventList(message) {
                try midiCheck(MIDISendEventList(output, endpoints.input, $0), "Send DAW event")
            }
        }
        XCTAssertEqual(receiver.waitFor(messages.count), messages)
        XCTAssertNil(engine.snapshot().fault)
    }

    func testMIDI2ConvertsOnlyAtLegacyDestination() throws {
        let modern = try VirtualFixture(midiProtocol: ._2_0)
        let legacy = try VirtualFixture()
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Mixed \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(
            sources: [modern.source, legacy.source], destinations: [modern.destination, legacy.destination])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [
            Route(source: modern.inputID, destination: modern.outputID),
            Route(source: modern.inputID, destination: legacy.outputID),
        ]
        try engine.update(session: session)
        let message = try XCTUnwrap(MIDIMessage(words: [0x4090_3C00, 0xABCD_0000], timestamp: mach_absolute_time()))
        try modern.send([message])
        XCTAssertEqual(modern.receiver.waitFor(1), [message])
        let converted = try XCTUnwrap(legacy.receiver.waitFor(1).first)
        XCTAssertEqual(converted.type, 2)
        XCTAssertEqual(converted.bytes, [0x90, 60, 0x55])
        XCTAssertEqual(converted.timestamp, message.timestamp)
        XCTAssertNil(engine.snapshot().fault)
    }

    func testLegacySourcesKeepBankAndParameterSelectionMessages() throws {
        let fixture = try VirtualFixture()
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Legacy Controls \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [Route(source: fixture.inputID, destination: fixture.outputID)]
        try engine.update(session: session)
        let timestamp = mach_absolute_time()
        let bytes: [[UInt8]] = [[0xB0, 0, 5], [0xB0, 32, 7], [0xB0, 101, 0], [0xB0, 100, 1]]
        let messages = try bytes.map { try XCTUnwrap(MIDIMessage(bytes: $0, timestamp: timestamp)) }
        try fixture.send(messages)
        XCTAssertEqual(fixture.receiver.waitFor(messages.count), messages)
        XCTAssertNil(engine.snapshot().fault)
    }

    func testActualCoreMIDIRouteChannelTransposeAndSysEx() throws {
        let fixture = try VirtualFixture()
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Integration \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.start()
        var session = engine.snapshot().session
        XCTAssertNotNil(session.setup.port(fixture.inputID))
        XCTAssertNotNil(session.setup.port(fixture.outputID))
        session.setup.routes = [
            Route(source: fixture.inputID, destination: fixture.outputID, channel: 9, transpose: 12)
        ]
        try engine.update(session: session)
        let timestamp = mach_absolute_time()
        let messages = [
            MIDIMessage.noteOn(60).replacing(timestamp: timestamp),
            try XCTUnwrap(MIDIMessage(words: [0x3016_7D01, 0x0203_0405], timestamp: timestamp)),
            try XCTUnwrap(MIDIMessage(words: [0x3031_0600, 0], timestamp: timestamp)),
            try XCTUnwrap(MIDIMessage(bytes: [0xF8], timestamp: timestamp)),
            MIDIMessage.noteOff(60).replacing(timestamp: timestamp),
        ]
        try fixture.send(messages)
        let delivered = fixture.receiver.waitFor(5)
        XCTAssertEqual(delivered.count, 5)
        XCTAssertEqual(delivered.first?.channel, 9)
        XCTAssertEqual(delivered.first?.data1, 72)
        XCTAssertEqual(delivered.first?.timestamp, timestamp)
        XCTAssertEqual(Array(delivered.dropFirst().prefix(3)), Array(messages.dropFirst().prefix(3)))
        XCTAssertTrue(delivered.last?.isNoteOff == true)
        XCTAssertEqual(delivered.last?.data1, 72)
        XCTAssertNil(engine.snapshot().fault)
    }

    func testVirtualOutputStampsZeroAndInputReceivesDAWTraffic() throws {
        let fixture = try VirtualFixture()
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Virtual \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [
            Route(source: MIDIEngine.virtualInputID, destination: fixture.outputID),
            Route(source: fixture.inputID, destination: MIDIEngine.virtualOutputID),
        ]
        try engine.update(session: session)
        let endpoints = engine.nativeEndpoints()
        var sendPort = MIDIPortRef()
        var receivePort = MIDIPortRef()
        let receiver = fixture.receiver
        try midiCheck(MIDIOutputPortCreate(fixture.client, "DAW Send" as CFString, &sendPort), "Create DAW output")
        try midiCheck(
            MIDIInputPortCreateWithProtocol(fixture.client, "DAW Receive" as CFString, ._1_0, &receivePort) { list, _ in
                receiver.receive(list)
            }, "Create DAW input")
        try midiCheck(MIDIPortConnectSource(receivePort, endpoints.output, nil), "Connect DAW input")
        try withEventList(MIDIMessage.noteOn(63)) {
            try midiCheck(MIDISendEventList(sendPort, endpoints.input, $0), "Send DAW message")
        }
        XCTAssertEqual(fixture.receiver.waitFor(1).first?.data1, 63)
        engine.inject(.noteOn(64), from: fixture.inputID)
        let delivered = fixture.receiver.waitFor(2)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered.last?.data1, 64)
        XCTAssertGreaterThan(delivered.last?.timestamp ?? 0, 0)

    }

    func testMonitorOverflowDoesNotDropRoutedEvents() throws {
        let fixture = try VirtualFixture()
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Load \(UUID().uuidString)", monitorCapacity: 8)
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [Route(source: fixture.inputID, destination: fixture.outputID)]
        try engine.update(session: session)
        for index in 0..<128 {
            try fixture.send([try XCTUnwrap(MIDIMessage(bytes: [0xB0, 1, UInt8(index)]))])
        }
        let delivered = fixture.receiver.waitFor(128)
        XCTAssertEqual(delivered.count, 128)
        XCTAssertEqual(delivered.map(\.data2), (0..<128).map(UInt8.init))
        let snapshot = engine.snapshot()
        XCTAssertGreaterThan(snapshot.droppedMonitorRecords, 0)
        XCTAssertNil(snapshot.fault)
    }

    func testVirtualIdentitiesPersistWithoutStealingCollision() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("virtual.json")
        let first = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Identity", identityURL: url)
        try first.selectEndpoints(sources: [], destinations: [])
        try first.start()
        let bytes = try Data(contentsOf: url)
        let collision = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Collision", identityURL: url)
        try collision.selectEndpoints(sources: [], destinations: [])
        XCTAssertThrowsError(try collision.start())
        collision.stop()
        first.stop()
        let restarted = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Identity", identityURL: url)
        defer { restarted.stop() }
        try restarted.selectEndpoints(sources: [], destinations: [])
        try restarted.start()
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testFanOutMergeAndProgramChangeOnRealPorts() throws {
        let first = try VirtualFixture()
        let second = try VirtualFixture()
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Merge \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(
            sources: [first.source, second.source], destinations: [first.destination, second.destination])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [
            Route(source: first.inputID, destination: first.outputID),
            Route(source: first.inputID, destination: second.outputID),
            Route(source: second.inputID, destination: first.outputID),
        ]
        var recalled = session.setup
        recalled.routes = [Route(source: first.inputID, destination: second.outputID, transpose: 12)]
        let preset = Preset(name: "Octave", program: 9, setup: recalled)
        session.presets = [preset]
        session.programChangeSources = [first.inputID]
        try engine.update(session: session)
        try first.send([.noteOn(60)])
        XCTAssertEqual(first.receiver.waitFor(1).first?.data1, 60)
        XCTAssertEqual(second.receiver.waitFor(1).first?.data1, 60)
        try second.send([.noteOn(65)])
        XCTAssertEqual(first.receiver.waitFor(2).last?.data1, 65)
        try first.send([try XCTUnwrap(MIDIMessage(bytes: [0xC0, 9])), .noteOn(60)])
        let delivered = second.receiver.waitFor(3)
        XCTAssertEqual(delivered.count, 3)
        XCTAssertTrue(delivered[1].isNoteOff)
        XCTAssertEqual(delivered.last?.data1, 72)
        XCTAssertEqual(engine.snapshot().activePreset, preset.id)
        XCTAssertTrue(first.receiver.waitFor(4).suffix(2).allSatisfy(\.isNoteOff))
    }

    func testSourceDisconnectReleasesNotesAndReconnectRestoresRoute() throws {
        let fixture = try VirtualFixture()
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Hotplug \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.start()
        let sourceID = fixture.inputID
        var uid: Int32 = 0
        try midiCheck(MIDIObjectGetIntegerProperty(fixture.source, kMIDIPropertyUniqueID, &uid), "Read source identity")
        var session = engine.snapshot().session
        session.setup.routes = [Route(source: sourceID, destination: fixture.outputID)]
        try engine.update(session: session)
        try fixture.send([.noteOn(60)])
        XCTAssertEqual(fixture.receiver.waitFor(1).count, 1)
        try midiCheck(MIDIEndpointDispose(fixture.source), "Disconnect fixture source")
        fixture.source = 0
        try engine.refresh()
        XCTAssertTrue(fixture.receiver.waitFor(2).last?.isNoteOff == true)
        let offline = engine.snapshot()
        XCTAssertFalse(offline.online.contains(sourceID))
        XCTAssertNotNil(offline.session.setup.port(sourceID))
        XCTAssertEqual(offline.session.setup.routes.count, 1)
        try midiCheck(
            MIDISourceCreateWithProtocol(fixture.client, "Reconnected Test" as CFString, ._1_0, &fixture.source),
            "Reconnect fixture")
        try midiCheck(MIDIObjectSetIntegerProperty(fixture.source, kMIDIPropertyPrivate, 1), "Hide reconnected fixture")
        try midiCheck(
            MIDIObjectSetIntegerProperty(fixture.source, kMIDIPropertyUniqueID, uid), "Restore fixture identity")
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.refresh()
        try fixture.send([.noteOn(67)])
        XCTAssertEqual(fixture.receiver.waitFor(3).last?.data1, 67)
        XCTAssertTrue(engine.snapshot().online.contains(sourceID))
    }

    func testMissingDestinationDoesNotPauseInputOrReleaseAnotherLayer() throws {
        let first = try VirtualFixture(midiProtocol: ._2_0)
        let second = try VirtualFixture(midiProtocol: ._2_0)
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Output Hotplug \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [first.source], destinations: [first.destination, second.destination])
        try engine.start()
        var uid: Int32 = 0
        try midiCheck(
            MIDIObjectGetIntegerProperty(first.destination, kMIDIPropertyUniqueID, &uid), "Read output identity")
        var session = engine.snapshot().session
        session.setup.routes = [
            Route(source: first.inputID, destination: first.outputID),
            Route(source: first.inputID, destination: second.outputID),
        ]
        try engine.update(session: session)
        let on = try XCTUnwrap(MIDIMessage(words: [0x4090_3C00, 0xABCD_0000]))
        let off = try XCTUnwrap(MIDIMessage(words: [0x4080_3C00, 0x9876_0000]))
        let control = try XCTUnwrap(MIDIMessage(words: [0x40B0_0100, 0x1234_5678]))
        let marker = try XCTUnwrap(MIDIMessage(words: [0x40B0_0200, 0x8765_4321]))
        try first.send([on])
        XCTAssertEqual(first.receiver.waitFor(1).count, 1)
        XCTAssertEqual(second.receiver.waitFor(1).count, 1)
        try midiCheck(MIDIEndpointDispose(first.destination), "Disconnect output")
        first.destination = 0
        try engine.refresh()
        XCTAssertNil(engine.snapshot().fault)
        try first.send([control, off, on.replacing(note: 64)])
        XCTAssertEqual(
            second.receiver.waitFor(4).map(\.words), [on.words, control.words, off.words, on.replacing(note: 64).words])
        let receiver = first.receiver
        try midiCheck(
            MIDIDestinationCreateWithProtocol(first.client, "Reconnected Output" as CFString, ._2_0, &first.destination)
            {
                list, _ in receiver.receive(list)
            }, "Reconnect output")
        try midiCheck(MIDIObjectSetIntegerProperty(first.destination, kMIDIPropertyPrivate, 1), "Hide output")
        try midiCheck(
            MIDIObjectSetIntegerProperty(first.destination, kMIDIPropertyUniqueID, uid), "Restore output identity")
        try engine.selectEndpoints(sources: [first.source], destinations: [first.destination, second.destination])
        try first.send([off.replacing(note: 64), marker])
        XCTAssertEqual(first.receiver.waitFor(2).map(\.words), [on.words, marker.words])
        XCTAssertEqual(
            second.receiver.waitFor(6).suffix(2).map(\.words), [off.replacing(note: 64).words, marker.words])
        XCTAssertNil(engine.snapshot().fault)
    }

    func testRestartedVirtualInputCanReleaseTheSameNoteAgain() throws {
        let fixture = try VirtualFixture(midiProtocol: ._2_0)
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Restart \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [], destinations: [fixture.destination])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [Route(source: MIDIEngine.virtualInputID, destination: fixture.outputID)]
        try engine.update(session: session)
        var port = MIDIPortRef()
        try midiCheck(MIDIOutputPortCreate(fixture.client, "DAW Send" as CFString, &port), "Create DAW output")
        let on = try XCTUnwrap(MIDIMessage(words: [0x4090_3C00, 0xABCD_0000]))
        let off = try XCTUnwrap(MIDIMessage(words: [0x4080_3C00, 0x9876_0000]))
        func send(_ message: MIDIMessage) throws {
            let input = engine.nativeEndpoints().input
            try withEventList(message) { try midiCheck(MIDISendEventList(port, input, $0), "Send DAW event") }
        }
        try send(try XCTUnwrap(MIDIMessage(words: [0x4000_3C03, 0x9000_0000])))
        XCTAssertEqual(fixture.receiver.waitFor(1).count, 1)
        try send(on)
        XCTAssertEqual(fixture.receiver.waitFor(3).count, 3)
        engine.stop()
        XCTAssertEqual(fixture.receiver.waitFor(5).last?.isNoteOff, true)
        try engine.start()
        try send(on)
        try send(off)
        let received = fixture.receiver.waitFor(7)
        XCTAssertEqual(received.count, 7)
        XCTAssertEqual(received.suffix(2).map(\.words), [on.words, off.words])
    }

    func testPacketsFromAnotherConnectionContextAreIgnored() throws {
        let fixture = try VirtualFixture()
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Connection Epoch \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [Route(source: fixture.inputID, destination: fixture.outputID)]
        try engine.update(session: session)
        let stale = SourceContext(id: fixture.inputID)
        withEventList(MIDIMessage.noteOn(60)) { engine.ingest($0, source: stale) }
        engine.flush()
        XCTAssertEqual(engine.snapshot().totalMessages, 0)
        try fixture.send([.noteOn(64)])
        XCTAssertEqual(fixture.receiver.waitFor(1).map(\.data1), [64])
    }

    func testReconnectedSourceCanReleaseTheSameNoteAgain() throws {
        let fixture = try VirtualFixture(midiProtocol: ._2_0)
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Reconnect \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.start()
        let sourceID = fixture.inputID
        var uid: Int32 = 0
        try midiCheck(
            MIDIObjectGetIntegerProperty(fixture.source, kMIDIPropertyUniqueID, &uid), "Read fixture identity")
        var session = engine.snapshot().session
        session.setup.routes = [Route(source: sourceID, destination: fixture.outputID)]
        try engine.update(session: session)
        let on = try XCTUnwrap(MIDIMessage(words: [0x4090_3C00, 0xABCD_0000]))
        let off = try XCTUnwrap(MIDIMessage(words: [0x4080_3C00, 0x9876_0000]))
        try fixture.send([on])
        XCTAssertEqual(fixture.receiver.waitFor(1).count, 1)
        try midiCheck(MIDIEndpointDispose(fixture.source), "Disconnect fixture")
        fixture.source = 0
        try engine.refresh()
        XCTAssertEqual(fixture.receiver.waitFor(2).last?.isNoteOff, true)
        try midiCheck(
            MIDISourceCreateWithProtocol(fixture.client, "Reconnected Source" as CFString, ._2_0, &fixture.source),
            "Reconnect fixture")
        try midiCheck(MIDIObjectSetIntegerProperty(fixture.source, kMIDIPropertyPrivate, 1), "Hide fixture")
        try midiCheck(MIDIObjectSetIntegerProperty(fixture.source, kMIDIPropertyUniqueID, uid), "Restore identity")
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try fixture.send([on, off])
        let received = fixture.receiver.waitFor(4)
        XCTAssertEqual(received.count, 4)
        XCTAssertEqual(received.last?.words, off.words)
        XCTAssertNil(engine.snapshot().fault)
    }

    func testVariableLengthPacketBeyondInlineWordTuple() throws {
        let fixture = try VirtualFixture()
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Packet \(UUID().uuidString)")
        defer { engine.stop() }
        try engine.selectEndpoints(sources: [fixture.source], destinations: [fixture.destination])
        try engine.start()
        var session = engine.snapshot().session
        session.setup.routes = [Route(source: fixture.inputID, destination: fixture.outputID)]
        try engine.update(session: session)
        let words = (0..<200).map { UInt32(0x20B0_0100) | UInt32($0 % 128) }
        let timestamp = mach_absolute_time()
        try withUnsafeTemporaryAllocation(byteCount: 4096, alignment: MemoryLayout<MIDIEventList>.alignment) {
            storage in
            let list = storage.baseAddress!.assumingMemoryBound(to: MIDIEventList.self)
            let first = MIDIEventListInit(list, ._1_0)
            words.withUnsafeBufferPointer { buffer in
                _ = MIDIEventListAdd(list, 4096, first, timestamp, words.count, buffer.baseAddress!)
            }
            XCTAssertEqual(decodeEventList(UnsafePointer(list)).count, words.count)
            try midiCheck(MIDIReceivedEventList(fixture.source, list), "Publish variable-length packet")
        }
        let delivered = fixture.receiver.waitFor(200)
        XCTAssertEqual(delivered.map { $0.words[0] }, words)
        XCTAssertTrue(delivered.allSatisfy { $0.timestamp == timestamp })
    }

    func testOversizedVirtualIdentityFileIsRejectedBeforeDecoding() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("virtual.json")
        try Data(repeating: 32, count: 4097).write(to: url)
        let engine = try MIDIEngine(
            session: Session(), privateEndpoints: true, name: "Router Invalid Identity", identityURL: url)
        XCTAssertThrowsError(try engine.start()) { error in
            XCTAssertTrue(error.localizedDescription.contains("4 KiB"))
        }
    }

    func testBoundedInboxSuspendsOverflowingSourceUntilReset() {
        let inbox = MIDIInbox(capacity: 2)
        inbox.setAccepting(true)
        let source = SourceContext(id: "test")
        let event = RawEvent(source: source, timestamp: 1, count: 1, a: 0x2090_3C64)
        XCTAssertTrue(inbox.push(event))
        XCTAssertTrue(inbox.push(event))
        XCTAssertFalse(inbox.push(event))
        let batch = inbox.take(limit: 2)
        XCTAssertEqual(batch.overflows, ["test"])
        XCTAssertTrue(inbox.isSuspended("test"))
        XCTAssertFalse(inbox.push(event))
        inbox.reset(accepting: true)
        XCTAssertTrue(inbox.push(event))
    }
}
