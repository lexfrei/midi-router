import Foundation

public struct Delivery: Equatable, Sendable {
    public var destination: String
    public var message: MIDIMessage
    public var routeID: UUID?
    public init(destination: String, message: MIDIMessage, routeID: UUID? = nil) {
        self.destination = destination
        self.message = message
        self.routeID = routeID
    }
}

public struct RoutingResult: Sendable {
    public var deliveries: [Delivery] = []
    public var recalledPreset: UUID?
    public var fault: String?
    public var diagnostics: [String] = []
}

private struct HeldKey: Hashable {
    var source: String
    var group: UInt8
    var channel: Int
    var note: UInt8
}
private struct OutputKey: Hashable {
    var destination: String
    var group: UInt8
    var channel: Int
    var note: UInt8
}
private struct HeldNote {
    var output: OutputKey
    var routeID: UUID
    var transpose: Int
    var usesPitchController: Bool
    var detached = false
}
private struct OutputNote {
    var count: Int
    var off: MIDIMessage
}
private struct PedalKey: Hashable {
    var destination: String
    var group: UInt8
    var channel: Int
}
private struct PedalOwner: Hashable {
    var source: String
    var group: UInt8
    var channel: Int
}
private struct HeldPedal {
    var owners: Set<PedalOwner>
    var off: MIDIMessage
}
private struct CompiledRoute {
    var route: Route
    var inputChannel: Int?
    var excludedInput: Set<Int>
    var outputChannel: Int?
    var excludedOutput: Set<Int>
}

public struct Router: Sendable {
    public private(set) var session: Session
    private var routes: [String: [CompiledRoute]] = [:]
    private var held: [HeldKey: [[HeldNote]]] = [:]
    private var notePitch: [HeldKey: MIDIMessage] = [:]
    private var perNoteOutputs: [OutputKey: Set<String>] = [:]
    private var outputNotes: [OutputKey: OutputNote] = [:]
    private var sustain: [PedalKey: HeldPedal] = [:]
    private var multipart = MultipartRouting()

    public init(session: Session) throws {
        try session.validate()
        self.session = session
        compile()
    }

    private mutating func compile() {
        routes = [:]
        let ports = Dictionary(uniqueKeysWithValues: session.setup.ports.map { ($0.id, $0) })
        notePitch = notePitch.filter { ports[$0.key.source]?.direction == .input }
        for route in session.setup.routes where route.enabled {
            guard let input = ports[route.source], let output = ports[route.destination] else { continue }
            let inChannel = input.slots.first { $0.id == route.sourceSlot }?.channel
            let outChannel = output.slots.first { $0.id == route.destinationSlot }?.channel
            routes[route.source, default: []].append(
                CompiledRoute(
                    route: route,
                    inputChannel: inChannel,
                    excludedInput: inChannel == nil ? Set(input.slots.map(\.channel)) : [],
                    outputChannel: outChannel ?? route.channel,
                    excludedOutput: outChannel == nil ? Set(output.slots.map(\.channel)) : []))
        }
    }

    private func slotConfiguration(_ setup: Setup) -> [String: [UUID: Int]] {
        let connected = Set(setup.routes.filter(\.enabled).flatMap { [$0.source, $0.destination] })
        return Dictionary(
            uniqueKeysWithValues: setup.ports.filter { connected.contains($0.id) }.map { port in
                (port.id, Dictionary(uniqueKeysWithValues: port.slots.map { ($0.id, $0.channel) }))
            })
    }

    public mutating func replaceSession(_ new: Session) throws -> [Delivery] {
        try new.validate()
        let changesRouting =
            new.setup.routes != session.setup.routes
            || slotConfiguration(new.setup) != slotConfiguration(session.setup)
        let ports = Dictionary(uniqueKeysWithValues: new.setup.ports.map { ($0.id, $0.direction) })
        var releases: [Delivery] = []
        for port in session.setup.ports where port.direction == .output && ports[port.id] != .output {
            releases += multipart.disconnect(destination: port.id)
        }
        if changesRouting { releases += releaseOwnedNotes(timestamp: 0) }
        for port in session.setup.ports where port.direction == .input && ports[port.id] != .input {
            releases += multipart.disconnect(source: port.id, timestamp: 0)
        }
        multipart.interrupt(deliveries: releases)
        session = new
        compile()
        return releases
    }

    public mutating func receive(
        _ message: MIDIMessage, from source: String, canDeliver: (String) -> Bool = { _ in true }
    ) -> RoutingResult {
        let expired = multipart.expire(now: ProcessInfo.processInfo.systemUptime, timestamp: message.timestamp)
            .filter { canDeliver($0.destination) }
        multipart.interrupt(deliveries: expired)
        var result = receiveMessage(message, from: source, canDeliver: canDeliver)
        multipart.interrupt(deliveries: result.deliveries, source: source)
        result.deliveries = expired + result.deliveries
        result.diagnostics = takeDiagnostics()
        return result
    }

    public mutating func takeDiagnostics() -> [String] {
        let result = multipart.diagnostics
        multipart.diagnostics.removeAll(keepingCapacity: true)
        return result
    }

    private mutating func receiveMessage(
        _ message: MIDIMessage, from source: String, canDeliver: (String) -> Bool
    ) -> RoutingResult {
        if MultipartRouting.handles(message) {
            return RoutingResult(
                deliveries: multipart.receive(
                    message, source: source,
                    candidates: multipartCandidates(message, source: source, canDeliver: canDeliver),
                    now: ProcessInfo.processInfo.systemUptime, canDeliver: canDeliver))
        }
        // Utility clocks and endpoint discovery belong to the originating connection, not its routes.
        guard message.type != 0 && message.type != 15 else { return RoutingResult() }
        if let program = message.programNumber,
            session.programChangeSources.contains(source),
            let preset = session.presets.first(where: { $0.program == program })
        {
            let cleanup = releaseOwnedNotes(timestamp: message.timestamp)
            session.setup = preset.setup.retainingPorts(from: session.setup)
            compile()
            return RoutingResult(deliveries: cleanup, recalledPreset: preset.id)
        }
        if message.isNoteOn {
            let key = HeldKey(
                source: source, group: message.group, channel: message.channel!, note: message.noteNumber!)
            if (held[key]?.count ?? 0) >= 1024 {
                return RoutingResult(
                    deliveries: disconnect(source: source, timestamp: message.timestamp),
                    fault: "Too many repeated note-ons without matching note-offs.")
            }
        }
        if message.isNoteOff {
            let key = HeldKey(
                source: source, group: message.group, channel: message.channel!, note: message.noteNumber!)
            if held[key] != nil { return RoutingResult(deliveries: release(message, source: source)) }
        }
        var result = RoutingResult()
        let noteKey = message.noteNumber.map {
            HeldKey(source: source, group: message.group, channel: message.channel!, note: $0)
        }
        if let noteKey {
            if message.isPerNotePitch, session.setup.port(source)?.direction == .input {
                notePitch[noteKey] = message
            }
            if message.isPerNoteManagement {
                result.deliveries += manageNotes(message, key: noteKey)
            }
        }
        let inheritedPitch =
            message.type == 4 && message.isNoteOn && !message.hasPitchAttribute
            ? noteKey.flatMap { notePitch[$0] } : nil
        var channelLessDestinations = Set<String>()
        var newNotes: [HeldNote] = []
        for compiled in routes[source] ?? [] {
            let route = compiled.route
            guard canDeliver(route.destination) else { continue }
            var output = message
            if let channel = message.channel {
                guard
                    compiled.inputChannel.map({ $0 == channel }) ?? !compiled.excludedInput.contains(channel)
                else { continue }
                let targetChannel = compiled.outputChannel ?? channel
                guard !compiled.excludedOutput.contains(targetChannel) else { continue }
                var pitch: MIDIMessage?
                if let inheritedPitch {
                    guard let shifted = inheritedPitch.transposed(by: route.transpose) else { continue }
                    pitch = shifted.replacing(channel: targetChannel, timestamp: message.timestamp)
                }
                guard let transposed = output.transposed(by: route.transpose, noteIsIndex: pitch != nil) else {
                    continue
                }
                output = transposed.replacing(channel: targetChannel)
                if output.type == 4 && output.isPerNoteExpression {
                    let key = OutputKey(
                        destination: route.destination, group: output.group, channel: targetChannel,
                        note: output.noteNumber!)
                    if output.isPerNoteManagement {
                        if output.data2 & 1 != 0 { perNoteOutputs[key] = nil }
                    } else {
                        perNoteOutputs[key, default: []].insert(source)
                    }
                }
                if let pitch {
                    result.deliveries.append(
                        Delivery(destination: route.destination, message: pitch, routeID: route.id))
                }
                if message.isNoteOn {
                    let key = OutputKey(
                        destination: route.destination, group: output.group, channel: targetChannel,
                        note: output.noteNumber!)
                    outputNotes[key] = OutputNote(count: (outputNotes[key]?.count ?? 0) + 1, off: output.endingNote())
                    if pitch != nil { perNoteOutputs[key, default: []].insert(source) }
                    newNotes.append(
                        HeldNote(
                            output: key, routeID: route.id, transpose: route.transpose,
                            usesPitchController: pitch != nil))
                }
                if message.isSustain {
                    let key = PedalKey(
                        destination: route.destination, group: output.group, channel: targetChannel)
                    let owner = PedalOwner(source: source, group: message.group, channel: channel)
                    if message.sustainIsDown {
                        var pedal = sustain[key] ?? HeldPedal(owners: [], off: output.releasingSustain())
                        pedal.owners.insert(owner)
                        sustain[key] = pedal
                    } else {
                        sustain[key]?.owners.remove(owner)
                        if sustain[key]?.owners.isEmpty == false { continue }
                        sustain[key] = nil
                    }
                }
            } else {
                guard channelLessDestinations.insert(route.destination).inserted else { continue }
            }
            result.deliveries.append(
                Delivery(destination: route.destination, message: output, routeID: route.id))
        }
        if message.isNoteOn, let channel = message.channel {
            let key = HeldKey(source: source, group: message.group, channel: channel, note: message.noteNumber!)
            held[key, default: []].append(newNotes)
        }
        return result
    }

    private func multipartCandidates(_ message: MIDIMessage, source: String, canDeliver: (String) -> Bool) -> [Delivery]
    {
        var destinations = Set<String>()
        return (routes[source] ?? []).compactMap { compiled in
            guard canDeliver(compiled.route.destination) else { return nil }
            var output = message
            if let channel = message.channel {
                guard compiled.inputChannel.map({ $0 == channel }) ?? !compiled.excludedInput.contains(channel) else {
                    return nil
                }
                let target = compiled.outputChannel ?? channel
                guard !compiled.excludedOutput.contains(target) else { return nil }
                output = message.replacing(channel: target)
            } else {
                guard destinations.insert(compiled.route.destination).inserted else { return nil }
            }
            return Delivery(destination: compiled.route.destination, message: output, routeID: compiled.route.id)
        }
    }

    private mutating func manageNotes(_ message: MIDIMessage, key: HeldKey) -> [Delivery] {
        let reset = message.data2 & 1 != 0
        let detach = message.data2 & 2 != 0
        if reset { notePitch[key] = nil }
        guard let instances = held[key] else { return [] }
        var released: [HeldNote] = []
        held[key] = instances.map { notes in
            notes.compactMap { original in
                var note = original
                if detach { note.detached = true }
                if reset && !note.detached && note.usesPitchController
                    && !(0...127).contains(Int(key.note) + note.transpose)
                {
                    released.append(note)
                    return nil
                }
                return note
            }
        }
        return releaseNotes(released, timestamp: message.timestamp)
    }

    private mutating func release(_ message: MIDIMessage, source: String) -> [Delivery] {
        let key = HeldKey(
            source: source, group: message.group, channel: message.channel!, note: message.noteNumber!)
        guard var instances = held[key], !instances.isEmpty else { return [] }
        let notes = instances.removeFirst()
        held[key] = instances.isEmpty ? nil : instances
        return releaseNotes(notes, timestamp: message.timestamp, message: message)
    }

    private mutating func releaseNotes(_ notes: [HeldNote], timestamp: UInt64, message: MIDIMessage? = nil)
        -> [Delivery]
    {
        var deliveries: [Delivery] = []
        for note in notes {
            guard var output = outputNotes[note.output] else { continue }
            output.count -= 1
            if output.count > 0 {
                outputNotes[note.output] = output
                continue
            }
            outputNotes[note.output] = nil
            let off =
                message?.endingNote().transposed(by: note.transpose, noteIsIndex: true)?
                .replacing(channel: note.output.channel, note: note.output.note)
                ?? output.off
            deliveries.append(
                Delivery(
                    destination: note.output.destination,
                    message: off.replacing(timestamp: timestamp), routeID: note.routeID))
        }
        return deliveries
    }

    public mutating func disconnect(destination: String) {
        multipart.disconnect(destination: destination)
        held = held.mapValues { instances in
            instances.map { notes in notes.filter { $0.output.destination != destination } }
        }
        outputNotes = outputNotes.filter { $0.key.destination != destination }
        sustain = sustain.filter { $0.key.destination != destination }
        perNoteOutputs = perNoteOutputs.filter { $0.key.destination != destination }
    }

    @discardableResult
    public mutating func reconnect(source: String) -> [Delivery] {
        let aborted = multipart.disconnect(source: source, timestamp: 0)
        notePitch = notePitch.filter { $0.key.source != source }
        for key in Array(held.keys) where key.source == source {
            let active = held[key]!.filter { !$0.isEmpty }
            held[key] = active.isEmpty ? nil : active
        }
        multipart.interrupt(deliveries: aborted)
        return aborted
    }

    public mutating func disconnect(source: String, timestamp: UInt64 = 0) -> [Delivery] {
        let aborted = multipart.disconnect(source: source, timestamp: timestamp)
        notePitch = notePitch.filter { $0.key.source != source }
        var deliveries = aborted
        for key in Array(held.keys) where key.source == source {
            let instances = held[key]!
            deliveries += releaseNotes(instances.flatMap { $0 }, timestamp: timestamp)
            held[key] = instances.map { _ in [] }
        }
        for key in Array(sustain.keys) {
            var pedal = sustain[key]!
            pedal.owners = pedal.owners.filter { $0.source != source }
            if pedal.owners.isEmpty {
                deliveries.append(
                    Delivery(destination: key.destination, message: pedal.off.replacing(timestamp: timestamp)))
                sustain[key] = nil
            } else {
                sustain[key] = pedal
            }
        }
        for key in Array(perNoteOutputs.keys) {
            perNoteOutputs[key]?.remove(source)
            if perNoteOutputs[key]?.isEmpty == true {
                deliveries.append(resetPerNoteControllers(key, timestamp: timestamp))
                perNoteOutputs[key] = nil
            }
        }
        multipart.interrupt(deliveries: deliveries)
        return deliveries
    }

    private func resetPerNoteControllers(_ key: OutputKey, timestamp: UInt64) -> Delivery {
        let word =
            UInt32(0x40F0_0003) | UInt32(key.group) << 24
            | UInt32(key.channel - 1) << 16 | UInt32(key.note) << 8
        return Delivery(destination: key.destination, message: MIDIMessage(words: [word, 0], timestamp: timestamp)!)
    }

    public mutating func panic(timestamp: UInt64 = 0) -> [Delivery] {
        multipart.panic(timestamp: timestamp) + releaseOwnedNotes(timestamp: timestamp)
    }

    private mutating func releaseOwnedNotes(timestamp: UInt64) -> [Delivery] {
        var deliveries = perNoteOutputs.keys.map { resetPerNoteControllers($0, timestamp: timestamp) }
        deliveries += outputNotes.map { key, note in
            Delivery(destination: key.destination, message: note.off.replacing(timestamp: timestamp))
        }
        deliveries += sustain.map { key, pedal in
            Delivery(destination: key.destination, message: pedal.off.replacing(timestamp: timestamp))
        }
        held = held.mapValues { $0.map { _ in [] } }
        outputNotes = [:]
        sustain = [:]
        perNoteOutputs = [:]
        return deliveries
    }
}
