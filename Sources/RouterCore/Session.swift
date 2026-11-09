import Foundation

public enum Direction: String, Codable, CaseIterable, Sendable { case input, output }
public enum Room: String, Codable, CaseIterable, Sendable { case studio, terminal, glass, desktop }

public struct Position: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double = 0, y: Double = 0) {
        self.x = x
        self.y = y
    }
}

public struct Slot: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var channel: Int
    public init(id: UUID = UUID(), name: String, channel: Int) {
        self.id = id
        self.name = name
        self.channel = channel
    }
}

public struct RouterPort: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var direction: Direction
    public var alias: String
    public var hidden: Bool
    public var position: Position
    public var slots: [Slot]
    public var title: String { alias.isEmpty ? name : alias }
    public init(
        id: String, name: String, direction: Direction, alias: String = "", hidden: Bool = false,
        position: Position = Position(), slots: [Slot] = []
    ) {
        self.id = id
        self.name = name
        self.direction = direction
        self.alias = alias
        self.hidden = hidden
        self.position = position
        self.slots = slots
    }
}

public struct Route: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var source: String
    public var destination: String
    public var sourceSlot: UUID?
    public var destinationSlot: UUID?
    public var channel: Int?
    public var transpose: Int
    public var enabled: Bool
    public init(
        id: UUID = UUID(), source: String, destination: String, sourceSlot: UUID? = nil,
        destinationSlot: UUID? = nil, channel: Int? = nil, transpose: Int = 0, enabled: Bool = true
    ) {
        self.id = id
        self.source = source
        self.destination = destination
        self.sourceSlot = sourceSlot
        self.destinationSlot = destinationSlot
        self.channel = channel
        self.transpose = transpose
        self.enabled = enabled
    }
}

public struct Setup: Codable, Equatable, Sendable {
    public var ports: [RouterPort]
    public var routes: [Route]
    public init(ports: [RouterPort] = [], routes: [Route] = []) {
        self.ports = ports
        self.routes = routes
    }
    public func port(_ id: String) -> RouterPort? { ports.first { $0.id == id } }

    public func retainingPorts(from previous: Setup) -> Setup {
        var merged = self
        let ids = Set(ports.map(\.id))
        merged.ports.append(contentsOf: previous.ports.filter { !ids.contains($0.id) })
        return merged
    }

    public func validate() throws {
        guard Set(ports.map(\.id)).count == ports.count else {
            throw SessionError.invalid("Duplicate port identifiers.")
        }
        guard Set(routes.map(\.id)).count == routes.count else {
            throw SessionError.invalid("Duplicate route identifiers.")
        }
        for port in ports {
            guard !port.id.isEmpty, port.id.count <= 1024, port.name.count <= 1024,
                port.alias.count <= 256,
                port.position.x.isFinite, port.position.y.isFinite,
                abs(port.position.x) <= 100_000, abs(port.position.y) <= 100_000
            else {
                throw SessionError.invalid("Invalid port identity, name or position.")
            }
            guard Set(port.slots.map(\.id)).count == port.slots.count,
                Set(port.slots.map(\.channel)).count == port.slots.count
            else {
                throw SessionError.invalid("A port cannot have duplicate slots or slot channels.")
            }
            for slot in port.slots {
                guard (1...16).contains(slot.channel), !slot.name.isEmpty, slot.name.count <= 256 else {
                    throw SessionError.invalid("Slot channels must be 1–16 and names must be nonempty.")
                }
            }
        }
        for route in routes {
            guard let source = port(route.source), source.direction == .input,
                let destination = port(route.destination), destination.direction == .output
            else {
                throw SessionError.invalid("A route must connect an existing input to an existing output.")
            }
            guard route.channel.map({ (1...16).contains($0) }) ?? true,
                (-127...127).contains(route.transpose)
            else {
                throw SessionError.invalid("Route channel or transposition is out of range.")
            }
            if let slot = route.sourceSlot, !source.slots.contains(where: { $0.id == slot }) {
                throw SessionError.invalid("The route's input slot no longer exists.")
            }
            if let slot = route.destinationSlot, !destination.slots.contains(where: { $0.id == slot }) {
                throw SessionError.invalid("The route's output slot no longer exists.")
            }
        }
    }
}

public struct Preset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var program: Int?
    public var setup: Setup
    public init(id: UUID = UUID(), name: String, program: Int? = nil, setup: Setup) {
        self.id = id
        self.name = name
        self.program = program
        self.setup = setup
    }
}

public struct Session: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var setup: Setup
    public var presets: [Preset]
    public var programChangeSources: Set<String>
    public var room: Room
    public var textScale: Double
    public init(
        setup: Setup = Setup(), presets: [Preset] = [], programChangeSources: Set<String> = [],
        room: Room = .studio, textScale: Double = 1
    ) {
        self.setup = setup
        self.presets = presets
        self.programChangeSources = programChangeSources
        self.room = room
        self.textScale = textScale
    }
    public func validate() throws {
        guard version == 1 else {
            throw SessionError.invalid("Unsupported session version: \(version).")
        }
        guard textScale.isFinite, (1...2).contains(textScale) else {
            throw SessionError.invalid("Text size must be 100–200%.")
        }
        try setup.validate()
        guard Set(presets.map(\.id)).count == presets.count else {
            throw SessionError.invalid("Duplicate preset identifiers.")
        }
        let programs = presets.compactMap(\.program)
        guard Set(programs).count == programs.count else {
            throw SessionError.invalid("Program Change assignments must be unique.")
        }
        for preset in presets {
            guard !preset.name.isEmpty, preset.name.count <= 256,
                preset.program.map({ (0...127).contains($0) }) ?? true
            else {
                throw SessionError.invalid("Preset names must be nonempty and programs must be 0–127.")
            }
            try preset.setup.validate()
        }
        guard
            programChangeSources.allSatisfy({ id in
                setup.ports.contains { $0.id == id && $0.direction == .input }
                    || presets.contains { $0.setup.ports.contains { $0.id == id && $0.direction == .input } }
            })
        else { throw SessionError.invalid("A preset trigger must reference a known input.") }
    }
}

public enum SessionError: LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let message) = self { message } else { nil }
    }
}
