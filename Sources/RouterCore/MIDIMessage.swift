import Foundation

public struct MIDIMessage: Equatable, Sendable {
    public private(set) var words: [UInt32]
    public var timestamp: UInt64
    public var type: UInt32 { words[0] >> 28 }
    public var group: UInt8 { UInt8((words[0] >> 24) & 15) }
    public var groupNumber: Int? { [1, 2, 3, 4, 5, 13].contains(type) ? Int(group) + 1 : nil }
    public var umpHex: String { words.map { String(format: "%08X", $0) }.joined(separator: " ") }
    public var status: UInt8 { UInt8((words[0] >> 16) & 255) }
    public var data1: UInt8 { UInt8((words[0] >> 8) & 255) }
    public var data2: UInt8 { UInt8(words[0] & 255) }
    public var channel: Int? {
        if (type == 2 && (0x80...0xEF).contains(status))
            || (type == 4 && status >> 4 != 7)
            || (type == 13 && words[0] & 0x0030_0000 == 0)
        {
            return Int(status & 15) + 1
        }
        return nil
    }
    public var noteNumber: UInt8? {
        let command = status >> 4
        if type == 2 && (8...10).contains(command) { return data1 & 127 }
        if type == 4 && [0, 1, 6, 8, 9, 10, 15].contains(command) { return data1 & 127 }
        return nil
    }
    public var isPerNoteExpression: Bool { noteNumber != nil && !isNoteOn && !isNoteOff }
    public var isPerNotePitch: Bool { type == 4 && status >> 4 == 0 && data2 == 3 }
    public var isPerNoteManagement: Bool { type == 4 && status >> 4 == 15 }
    public var hasPitchAttribute: Bool { type == 4 && (isNoteOn || isNoteOff) && data2 == 3 }
    public var sustainIsDown: Bool { isSustain && (type == 4 ? words[1] >= 0x8000_0000 : data2 & 127 >= 64) }
    public var isNoteOn: Bool {
        (type == 2 || type == 4) && status & 0xF0 == 0x90 && (type == 4 || data2 & 127 > 0)
    }
    public var isNoteOff: Bool {
        (type == 2 || type == 4) && (status & 0xF0 == 0x80 || (type == 2 && status & 0xF0 == 0x90 && data2 & 127 == 0))
    }
    public var isSustain: Bool { (type == 2 || type == 4) && status & 0xF0 == 0xB0 && data1 & 127 == 64 }
    public var programNumber: Int? {
        guard (type == 2 || type == 4) && status & 0xF0 == 0xC0 else { return nil }
        return type == 4 ? Int((words[1] >> 24) & 127) : Int(data1 & 127)
    }

    public static func wordCount(for first: UInt32) -> Int {
        switch first >> 28 {
        case 0, 1, 2, 6, 7: 1
        case 3, 4, 8, 9, 10: 2
        case 11, 12: 3
        default: 4
        }
    }

    public init?(words: [UInt32], timestamp: UInt64 = 0) {
        guard let first = words.first, words.count == Self.wordCount(for: first) else { return nil }
        let type = first >> 28
        switch type {
        case 3:
            let form = (first >> 20) & 15
            let count = Int((first >> 16) & 15)
            if form > 3 { break }
            guard count <= 6 else { return nil }
            let bytes =
                [UInt8((first >> 8) & 255), UInt8(first & 255)]
                + (0..<4).map { UInt8((words[1] >> (24 - $0 * 8)) & 255) }
            guard bytes.prefix(count).allSatisfy({ $0 < 128 }) else { return nil }
        case 5:
            let form = (first >> 20) & 15
            let count = (first >> 16) & 15
            if form <= 3, !(1...14).contains(count), !(form == 3 && count == 15) { return nil }
        default: break
        }
        self.words = words
        self.timestamp = timestamp
    }

    public init?(bytes: [UInt8], timestamp: UInt64 = 0) {
        guard let status = bytes.first, status >= 0x80, bytes.count <= 3 else { return nil }
        let data = Array(bytes.dropFirst())
        guard data.allSatisfy({ $0 < 128 }) else { return nil }
        let required: Int
        switch status {
        case 0x80...0xBF, 0xE0...0xEF, 0xF2: required = 3
        case 0xC0...0xDF, 0xF1, 0xF3: required = 2
        case 0xF6, 0xF8, 0xFA, 0xFB, 0xFC, 0xFE, 0xFF: required = 1
        default: return nil
        }
        guard bytes.count >= required else { return nil }
        let first = UInt32(status < 0xF0 ? 2 : 1) << 28 | UInt32(status) << 16
        let d1 = required > 1 ? UInt32(bytes[1]) << 8 : 0
        let d2 = required > 2 ? UInt32(bytes[2]) : 0
        self.init(words: [first | d1 | d2], timestamp: timestamp)
    }

    public static func noteOn(_ note: UInt8, channel: Int = 1, velocity: UInt8 = 100) -> MIDIMessage {
        precondition((1...16).contains(channel) && note < 128 && velocity < 128)
        return MIDIMessage(bytes: [0x90 | UInt8(channel - 1), note, velocity])!
    }
    public static func noteOff(_ note: UInt8, channel: Int = 1) -> MIDIMessage {
        precondition((1...16).contains(channel) && note < 128)
        return MIDIMessage(bytes: [0x80 | UInt8(channel - 1), note, 0])!
    }
    public var bytes: [UInt8] {
        if type == 3 && status >> 4 <= 3 {
            let payload = [data1, data2] + (0..<4).map { UInt8((words[1] >> (24 - $0 * 8)) & 255) }
            return Array(payload.prefix(Int((words[0] >> 16) & 15)))
        }
        let count: Int
        switch (type, status) {
        case (1, 0xF1), (1, 0xF3): count = 2
        case (1, 0xF2): count = 3
        case (1, 0xF6), (1, 0xF8), (1, 0xFA...0xFC), (1, 0xFE...0xFF): count = 1
        case (2, 0xC0...0xDF): count = 2
        case (2, 0x80...0xEF): count = 3
        default:
            return words.flatMap { word in (0..<4).map { UInt8((word >> (24 - $0 * 8)) & 255) } }
        }
        return Array([status, data1 & 127, data2 & 127].prefix(count))
    }
    public func replacing(channel: Int? = nil, note: UInt8? = nil, timestamp: UInt64? = nil)
        -> MIDIMessage
    {
        var copy = self
        if let channel, self.channel != nil {
            precondition((1...16).contains(channel))
            copy.words[0] = (copy.words[0] & ~0x000F_0000) | UInt32(channel - 1) << 16
        }
        if let note, noteNumber != nil {
            precondition(note < 128)
            copy.words[0] = (copy.words[0] & ~0x0000_7F00) | UInt32(note) << 8
        }
        if let timestamp { copy.timestamp = timestamp }
        return copy
    }
    func transposed(by semitones: Int, noteIsIndex: Bool = false) -> MIDIMessage? {
        guard let noteNumber else { return self }
        guard (-127...127).contains(semitones) else { return nil }
        let note = Int(noteNumber) + semitones
        let indexOnly = type == 4 && (noteIsIndex || hasPitchAttribute || isPerNoteExpression || isNoteOff)
        guard indexOnly || (0...127).contains(note) else { return nil }
        // UMP 1.1.2 §7.4.15: absolute pitch is independent of the rotating note index.
        var copy = replacing(note: UInt8((note + 128) % 128))
        if hasPitchAttribute {
            let pitch = Int(words[1] & 0xFFFF) + semitones * 512
            guard (0...65535).contains(pitch) else { return nil }
            copy.words[1] = (words[1] & 0xFFFF_0000) | UInt32(pitch)
        }
        if isPerNotePitch {
            let pitch = Int64(words[1]) + Int64(semitones) * (1 << 25)
            guard (0...Int64(UInt32.max)).contains(pitch) else { return nil }
            copy.words[1] = UInt32(pitch)
        }
        return copy
    }
    func endingNote(timestamp: UInt64? = nil) -> MIDIMessage {
        precondition(isNoteOn || isNoteOff)
        var copy = replacing(timestamp: timestamp)
        copy.words[0] = (words[0] & ~0x00F0_0000) | 0x0080_0000
        if !isNoteOff {
            copy.words[0] &= type == 4 ? ~0xFF : ~0x7F
            if type == 4 { copy.words[1] = 0 }
        }
        return copy
    }
    func releasingSustain(timestamp: UInt64? = nil) -> MIDIMessage {
        precondition(isSustain)
        var copy = replacing(timestamp: timestamp)
        if type == 4 { copy.words[1] = 0 } else { copy.words[0] &= ~0x7F }
        return copy
    }
    public var summary: String {
        if type == 4 { return "MIDI 2 " + midi2Summary }
        if type == 3 && status >> 4 <= 3 { return "SysEx7 (\(bytes.count) bytes)" }
        if type == 5 && status >> 4 <= 3 { return "SysEx8 · stream \(data1)" }
        if type == 5 && (8...9).contains(status >> 4) { return "Mixed Data Set" }
        if type == 0 { return "Utility · link-local" }
        if type == 13 { return "Flex Data" }
        if type == 15 { return "UMP Stream · endpoint-local" }
        if type == 1 {
            return [
                0xF8: "Clock", 0xFA: "Start", 0xFB: "Continue", 0xFC: "Stop", 0xFE: "Active Sensing",
                0xFF: "Reset",
            ][Int(status)] ?? "System \(String(format: "%02X", status))"
        }
        guard type == 2 else { return "UMP type \(String(type, radix: 16).uppercased())" }
        let data1 = self.data1 & 127
        let data2 = self.data2 & 127
        if isNoteOff { return "Note Off  \(data1)" }
        if isNoteOn { return "Note On   \(data1)  vel \(data2)" }
        switch status & 0xF0 {
        case 0xA0: return "Poly Pressure  \(data1)  \(data2)"
        case 0xB0: return "CC \(data1)  \(data2)"
        case 0xC0: return "Program Change  \(data1)"
        case 0xD0: return "Pressure  \(data1)"
        case 0xE0: return "Pitch Bend  \(Int(data2) * 128 + Int(data1) - 8192)"
        default: return "Channel Voice \(status >> 4)"
        }
    }
    private var midi2Summary: String {
        let value = words[1]
        let data1 = self.data1 & 127
        let data2 = status >> 4 <= 1 ? self.data2 : self.data2 & 127
        switch status >> 4 {
        case 0: return "Per-Note Registered CC \(data1):\(data2)  \(value)"
        case 1: return "Per-Note Assignable CC \(data1):\(data2)  \(value)"
        case 2: return "Registered CC \(data1):\(data2)  \(value)"
        case 3: return "Assignable CC \(data1):\(data2)  \(value)"
        case 4: return "Relative Registered CC \(data1):\(data2)  \(Int32(bitPattern: value))"
        case 5: return "Relative Assignable CC \(data1):\(data2)  \(Int32(bitPattern: value))"
        case 6: return "Per-Note Pitch Bend \(data1)  \(Int64(value) - 0x8000_0000)"
        case 8: return "Note Off  \(data1)  vel \(value >> 16)"
        case 9: return "Note On   \(data1)  vel \(value >> 16)"
        case 10: return "Poly Pressure  \(data1)  \(value)"
        case 11: return "CC \(data1)  \(value)"
        case 12: return "Program Change  \(programNumber!)"
        case 13: return "Pressure  \(value)"
        case 14: return "Pitch Bend  \(Int64(value) - 0x8000_0000)"
        case 15: return "Per-Note Management \(data1)  \(data2 & 3)"
        default: return "Channel Voice \(status >> 4)"
        }
    }
}
