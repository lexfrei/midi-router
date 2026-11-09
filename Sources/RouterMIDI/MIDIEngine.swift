import CoreMIDI
import Darwin
import Foundation
import RouterCore

public struct MonitorRecord: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let source: String
    public let destination: String?
    public let message: MIDIMessage
}

public struct EngineSnapshot: Sendable {
    public let session: Session
    public let online: Set<String>
    public let records: [MonitorRecord]
    public let totalMessages: UInt64
    public let droppedMonitorRecords: UInt64
    public let fault: String?
    public let activePreset: UUID?
    public let activity: [String: UInt64]
    public let diagnostics: [String]
}

private struct VirtualIdentities: Codable {
    var input: Int32
    var output: Int32
}
private struct SourceBinding {
    var endpoint: MIDIEndpointRef
    var port: MIDIPortRef
    var context: SourceContext
}

public final class MIDIEngine: @unchecked Sendable {
    private static let callbackGate = NSLock()
    public static let virtualInputID = "virtual:input"
    public static let virtualOutputID = "virtual:output"
    private let queue = DispatchQueue(label: "la.lex.midi-router.routing", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let signal: DispatchSourceUserDataAdd
    private let inbox: MIDIInbox
    private let name: String
    private let privateEndpoints: Bool
    private let identityURL: URL?
    private let monitorCapacity: Int
    private var router: Router
    private var client = MIDIClientRef()
    private var outputPort = MIDIPortRef()
    private var virtualDestination = MIDIEndpointRef()
    private var virtualSource = MIDIEndpointRef()
    private var bindings: [String: SourceBinding] = [:]
    private var virtualContext: SourceContext?
    private var destinations: [String: MIDIEndpointRef] = [:]
    private var endpointSelection: (sources: [MIDIEndpointRef], destinations: [MIDIEndpointRef])?
    private var online: Set<String> = []
    private var monitor: [MonitorRecord?]
    private var monitorHead = 0
    private var monitorCount = 0
    private var monitorID: UInt64 = 0
    private var totalMessages: UInt64 = 0
    private var droppedMonitorRecords: UInt64 = 0
    private var fault: String?
    private var diagnostics: [String] = []
    private var activePreset: UUID?
    private var activity: [String: UInt64] = [:]
    private var running = false

    public init(
        session: Session, privateEndpoints: Bool = false, name: String = "MIDI Router", identityURL: URL? = nil,
        inputCapacity: Int = 8192, monitorCapacity: Int = 2048
    ) throws {
        guard inputCapacity > 0, monitorCapacity > 0 else {
            throw SessionError.invalid("Buffer capacities must be positive.")
        }
        router = try Router(session: session)
        self.name = name
        self.privateEndpoints = privateEndpoints
        self.identityURL = identityURL
        self.monitorCapacity = monitorCapacity
        inbox = MIDIInbox(capacity: inputCapacity)
        monitor = Array(repeating: nil, count: monitorCapacity)
        signal = DispatchSource.makeUserDataAddSource(queue: queue)
        queue.setSpecific(key: queueKey, value: 1)
        signal.setEventHandler { [weak self] in self?.drain() }
        signal.resume()
    }
    deinit {
        stop()
        signal.cancel()
    }

    private func serialized<T>(_ action: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try action() }
        return try queue.sync(execute: action)
    }
    public static func endpointID(uniqueID: Int32, direction: Direction) -> String {
        "midi:\(direction.rawValue):\(uniqueID)"
    }

    public func start() throws {
        try serialized {
            guard !running else { return }
            do {
                Self.callbackGate.withLock {}
                try midiCheck(
                    MIDIClientCreateWithBlock(name as CFString, &client) { [weak self] _ in
                        Self.callbackGate.withLock {
                            guard let self else { return }
                            self.queue.async { [weak self] in
                                guard let self, self.running else { return }
                                do { try self.refreshOnQueue() } catch { self.fault = error.localizedDescription }
                            }
                        }
                    }, "Create MIDI client")
                try midiCheck(
                    MIDIOutputPortCreate(client, "\(name) Send" as CFString, &outputPort), "Create output port")
                let context = SourceContext(id: Self.virtualInputID)
                Self.callbackGate.withLock { virtualContext = context }
                try midiCheck(
                    MIDIDestinationCreateWithProtocol(client, "\(name) In" as CFString, ._2_0, &virtualDestination) {
                        [weak self] list, _ in
                        Self.callbackGate.withLock {
                            guard let self else { return }
                            self.ingest(list, source: context)
                        }
                    }, "Create virtual input")
                if privateEndpoints {
                    try midiCheck(
                        MIDIObjectSetIntegerProperty(virtualDestination, kMIDIPropertyPrivate, 1), "Hide virtual input")
                }
                try midiCheck(
                    MIDISourceCreateWithProtocol(client, "\(name) Out" as CFString, ._2_0, &virtualSource),
                    "Create virtual output")
                if privateEndpoints {
                    try midiCheck(
                        MIDIObjectSetIntegerProperty(virtualSource, kMIDIPropertyPrivate, 1), "Hide virtual output")
                }
                try restoreVirtualIdentities()
                send(router.reconnect(source: Self.virtualInputID), source: "[ Reconnect ]")
                running = true
                inbox.setAccepting(true)
                try refreshOnQueue()
            } catch {
                shutdown()
                throw error
            }
        }
    }

    public func update(session: Session) throws {
        try serialized {
            let releases = try router.replaceSession(session)
            send(releases, source: "[ Route Edit ]")
            activePreset = nil
            if running { try refreshOnQueue() }
        }
    }
    public func refresh() throws { try serialized { if running { try refreshOnQueue() } } }
    public func panic() {
        serialized { send(router.panic(timestamp: mach_absolute_time()), source: "[ All Notes Off ]") }
    }
    public func resume() {
        serialized {
            send(router.panic(timestamp: mach_absolute_time()), source: "[ Resume ]")
            inbox.reset(accepting: running)
            fault = nil
        }
    }
    public func stop() { serialized { shutdown() } }
    public func flush() { serialized { drain() } }
    func nativeEndpoints() -> (input: MIDIEndpointRef, output: MIDIEndpointRef) {
        serialized { (virtualDestination, virtualSource) }
    }
    func selectEndpoints(sources: [MIDIEndpointRef], destinations: [MIDIEndpointRef]) throws {
        try serialized {
            endpointSelection = (sources, destinations)
            if running { try refreshOnQueue() }
        }
    }

    public func inject(_ message: MIDIMessage, from source: String) {
        let context = SourceContext(id: source, synthetic: true)
        let words = message.words
        guard (1...4).contains(words.count) else { return }
        inbox.push(
            RawEvent(
                source: context, timestamp: message.timestamp, count: words.count,
                a: words[0], b: words.count > 1 ? words[1] : 0,
                c: words.count > 2 ? words[2] : 0, d: words.count > 3 ? words[3] : 0))
        signal.add(data: 1)
    }

    public func snapshot() -> EngineSnapshot {
        serialized {
            var records: [MonitorRecord] = []
            records.reserveCapacity(monitorCount)
            for _ in 0..<monitorCount {
                if let record = monitor[monitorHead] { records.append(record) }
                monitor[monitorHead] = nil
                monitorHead = (monitorHead + 1) % monitorCapacity
            }
            monitorCount = 0
            let diagnostics = self.diagnostics
            self.diagnostics = []
            return EngineSnapshot(
                session: router.session, online: online, records: records, totalMessages: totalMessages,
                droppedMonitorRecords: droppedMonitorRecords, fault: fault, activePreset: activePreset,
                activity: activity, diagnostics: diagnostics)
        }
    }

    func ingest(_ list: UnsafePointer<MIDIEventList>, source: SourceContext) {
        walkEventList(list) { timestamp, words, count in
            inbox.push(
                RawEvent(
                    source: source, timestamp: timestamp, count: count, a: words[0],
                    b: count > 1 ? words[1] : 0, c: count > 2 ? words[2] : 0, d: count > 3 ? words[3] : 0))
        }
        signal.add(data: 1)
    }
    private func drain() {
        guard running else { return }
        let batch = inbox.take(limit: 2048)
        for source in batch.overflows {
            fault =
                "Input buffer overflow for \(router.session.setup.port(source)?.title ?? source). Use Resume to restart inputs."
            send(router.disconnect(source: source, timestamp: mach_absolute_time()), source: source)
        }
        for event in batch.events {
            guard
                event.source.synthetic || event.source === virtualContext
                    || bindings[event.source.id]?.context === event.source
            else { continue }
            guard !inbox.isSuspended(event.source.id) else { continue }
            guard let message = event.message else {
                if event.a >> 28 != 0 { suspend(event.source.id, reason: "Unsupported or malformed MIDI packet.") }
                continue
            }
            totalMessages &+= 1
            activity[event.source.id] = mach_absolute_time()
            record(message, source: event.source.id, destination: nil)
            let result = router.receive(message, from: event.source.id) { destination in
                destination.hasPrefix("demo:") || destinations[destination] != nil
                    || (destination == Self.virtualOutputID && virtualSource != 0)
            }
            if let preset = result.recalledPreset { activePreset = preset }
            reportDiagnostics(result.diagnostics, source: event.source.id)
            send(result.deliveries, source: event.source.id)
            if let issue = result.fault { suspend(event.source.id, reason: issue) }
        }
        if batch.remaining { signal.add(data: 1) }
    }
    private func suspend(_ source: String, reason: String) {
        inbox.suspend(source)
        fault =
            "\(reason) Input \(router.session.setup.port(source)?.title ?? source) is suspended. Use Resume after correcting the problem."
        send(router.disconnect(source: source, timestamp: mach_absolute_time()), source: "[ Cleanup ]")
    }
    private func send(_ deliveries: [Delivery], source: String) {
        for delivery in deliveries {
            let message = delivery.message.replacing(
                timestamp: delivery.message.timestamp == 0 ? mach_absolute_time() : delivery.message.timestamp)
            let status: OSStatus
            if delivery.destination == Self.virtualOutputID, virtualSource != 0 {
                status = withEventList(message) { MIDIReceivedEventList(virtualSource, $0) }
            } else if delivery.destination.hasPrefix("demo:") {
                status = noErr
            } else if let endpoint = destinations[delivery.destination] {
                status = withEventList(message) { MIDISendEventList(outputPort, endpoint, $0) }
            } else {
                continue
            }
            if status != noErr {
                fault =
                    "Cannot send to \(router.session.setup.port(delivery.destination)?.title ?? delivery.destination) (OSStatus \(status))."
                online.remove(delivery.destination)
                if source != "[ Cleanup ]" { suspend(source, reason: fault!) }
                continue
            }
            activity[delivery.destination] = mach_absolute_time()
            record(message, source: source, destination: delivery.destination)
        }
        reportDiagnostics(router.takeDiagnostics(), source: source)
    }
    private func reportDiagnostics(_ messages: [String], source: String) {
        guard !messages.isEmpty else { return }
        let title = router.session.setup.port(source)?.title ?? source
        diagnostics.append(contentsOf: messages.map { "\(title): \($0)" })
        if diagnostics.count > 128 {
            let omitted = diagnostics.count - 128
            diagnostics.removeFirst(omitted)
            droppedMonitorRecords &+= UInt64(omitted)
        }
    }
    private func record(_ message: MIDIMessage, source: String, destination: String?) {
        monitorID &+= 1
        let record = MonitorRecord(id: monitorID, source: source, destination: destination, message: message)
        if monitorCount == monitorCapacity {
            monitor[monitorHead] = record
            monitorHead = (monitorHead + 1) % monitorCapacity
            droppedMonitorRecords &+= 1
        } else {
            monitor[(monitorHead + monitorCount) % monitorCapacity] = record
            monitorCount += 1
        }
    }

    private func refreshOnQueue() throws {
        var discovered: [RouterPort] = [
            RouterPort(id: Self.virtualInputID, name: "\(name) In", direction: .input),
            RouterPort(id: Self.virtualOutputID, name: "\(name) Out", direction: .output),
        ]
        var sources: [String: MIDIEndpointRef] = [:]
        var outputs: [String: MIDIEndpointRef] = [:]
        for direction in Direction.allCases {
            let selected = direction == .input ? endpointSelection?.sources : endpointSelection?.destinations
            let count =
                selected?.count ?? (direction == .input ? MIDIGetNumberOfSources() : MIDIGetNumberOfDestinations())
            for index in 0..<count {
                let endpoint =
                    selected?[index] ?? (direction == .input ? MIDIGetSource(index) : MIDIGetDestination(index))
                guard endpoint != 0, endpoint != virtualSource, endpoint != virtualDestination else { continue }
                var offline: Int32 = 0
                let offlineStatus = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
                guard offlineStatus == noErr || offlineStatus == kMIDIUnknownProperty else { continue }
                guard offline == 0 else { continue }
                let uid = try uniqueID(endpoint)
                guard uid != kMIDIInvalidUniqueID else {
                    fault = "A MIDI endpoint has no stable unique ID and cannot be routed safely."
                    continue
                }
                let id = Self.endpointID(uniqueID: uid, direction: direction)
                var rawName: Unmanaged<CFString>?
                var status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &rawName)
                if status != noErr { status = MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &rawName) }
                try midiCheck(status, "Read endpoint name")
                let title = rawName?.takeRetainedValue() as String? ?? "MIDI \(uid)"
                discovered.append(RouterPort(id: id, name: title, direction: direction))
                if direction == .input { sources[id] = endpoint } else { outputs[id] = endpoint }
            }
        }
        let disconnectedOutputs = Set(destinations.keys).subtracting(outputs.keys)
        destinations = outputs
        for id in disconnectedOutputs { router.disconnect(destination: id) }
        for (id, binding) in bindings where sources[id] != binding.endpoint {
            _ = MIDIPortDisconnectSource(binding.port, binding.endpoint)
            _ = MIDIPortDispose(binding.port)
            send(router.disconnect(source: id, timestamp: mach_absolute_time()), source: id)
            bindings[id] = nil
        }
        for (id, endpoint) in sources where bindings[id] == nil {
            let context = SourceContext(id: id)
            var port = MIDIPortRef()
            // Publish this connection to CoreMIDI's reused receive thread.
            Self.callbackGate.withLock {}
            try midiCheck(
                MIDIInputPortCreateWithProtocol(client, "\(name) Receive \(id)" as CFString, ._2_0, &port) {
                    [weak self] list, _ in
                    Self.callbackGate.withLock {
                        guard let self else { return }
                        self.ingest(list, source: context)
                    }
                }, "Create input port")
            do {
                try midiCheck(MIDIPortConnectSource(port, endpoint, nil), "Connect MIDI source")
            } catch {
                _ = MIDIPortDispose(port)
                throw error
            }
            send(router.reconnect(source: id), source: id)
            bindings[id] = SourceBinding(endpoint: endpoint, port: port, context: context)
        }
        online = Set(discovered.map(\.id))
        var session = router.session
        for port in discovered {
            if let index = session.setup.ports.firstIndex(where: { $0.id == port.id }) {
                session.setup.ports[index].name = port.name
            } else {
                session.setup.ports.append(port)
            }
        }
        let releases = try router.replaceSession(session)
        send(releases, source: "[ Discovery ]")
    }
    private func uniqueID(_ object: MIDIObjectRef) throws -> Int32 {
        var value: Int32 = 0
        try midiCheck(MIDIObjectGetIntegerProperty(object, kMIDIPropertyUniqueID, &value), "Read MIDI unique ID")
        return value
    }
    private func restoreVirtualIdentities() throws {
        if let url = identityURL, FileManager.default.fileExists(atPath: url.path) {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let data = try file.read(upToCount: 4097) ?? Data()
            guard data.count <= 4096 else { throw SessionError.invalid("Virtual MIDI identity file exceeds 4 KiB.") }
            let identities = try JSONDecoder().decode(VirtualIdentities.self, from: data)
            for (endpoint, id) in [(virtualDestination, identities.input), (virtualSource, identities.output)] {
                guard id != 0 else { throw SessionError.invalid("Saved virtual MIDI identity is invalid.") }
                var existing = MIDIObjectRef()
                let found = MIDIObjectFindByUniqueID(id, &existing, nil)
                guard found != noErr || existing == endpoint else {
                    throw SessionError.invalid(
                        "Virtual MIDI identity is already in use. Close the other instance before starting this session."
                    )
                }
                try midiCheck(
                    MIDIObjectSetIntegerProperty(endpoint, kMIDIPropertyUniqueID, id), "Restore virtual MIDI identity")
            }
        }
        guard let url = identityURL else { return }
        let identities = try VirtualIdentities(input: uniqueID(virtualDestination), output: uniqueID(virtualSource))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(identities).write(to: url, options: .atomic)
    }
    private func shutdown() {
        inbox.setAccepting(false)
        if running { send(router.panic(timestamp: mach_absolute_time()), source: "[ Shutdown ]") }
        running = false
        if client != 0 { MIDIClientDispose(client) }
        client = 0
        outputPort = 0
        virtualSource = 0
        virtualDestination = 0
        virtualContext = nil
        bindings = [:]
        destinations = [:]
        online = []
        inbox.reset(accepting: false)
    }
}
