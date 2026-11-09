import CoreMIDI
import Foundation
import RouterCore

func midiCheck(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw SessionError.invalid("\(operation) failed (OSStatus \(status)).") }
}

func withEventList<T>(_ message: MIDIMessage, _ body: (UnsafePointer<MIDIEventList>) throws -> T) rethrows -> T {
    try withUnsafeTemporaryAllocation(byteCount: 1024, alignment: MemoryLayout<MIDIEventList>.alignment) { storage in
        let list = storage.baseAddress!.assumingMemoryBound(to: MIDIEventList.self)
        let first = MIDIEventListInit(list, message.type <= 3 ? ._1_0 : ._2_0)
        message.words.withUnsafeBufferPointer { words in
            _ = MIDIEventListAdd(list, 1024, first, message.timestamp, words.count, words.baseAddress!)
        }
        return try body(UnsafePointer(list))
    }
}

func walkEventList(_ list: UnsafePointer<MIDIEventList>, _ visit: (UInt64, UnsafePointer<UInt32>, Int) -> Void) {
    // Value copies truncate variable-length packets to the inline Swift tuple.
    var packet = UnsafeRawPointer(list).advanced(by: MemoryLayout<MIDIEventList>.offset(of: \.packet)!)
        .assumingMemoryBound(to: MIDIEventPacket.self)
    for _ in 0..<list.pointee.numPackets {
        let words = UnsafeRawPointer(packet).advanced(by: MemoryLayout<MIDIEventPacket>.offset(of: \.words)!)
            .assumingMemoryBound(to: UInt32.self)
        var offset = 0
        while offset < packet.pointee.wordCount {
            let count = MIDIMessage.wordCount(for: words[offset])
            guard offset + count <= packet.pointee.wordCount else { return }
            visit(packet.pointee.timeStamp, words.advanced(by: offset), count)
            offset += count
        }
        packet = UnsafePointer(MIDIEventPacketNext(packet))
    }
}

func decodeEventList(_ list: UnsafePointer<MIDIEventList>) -> [MIDIMessage] {
    var messages: [MIDIMessage] = []
    walkEventList(list) { timestamp, words, count in
        if let message = MIDIMessage(
            words: Array(UnsafeBufferPointer(start: words, count: count)), timestamp: timestamp)
        {
            messages.append(message)
        }
    }
    return messages
}

final class SourceContext: Sendable {
    let id: String
    let synthetic: Bool
    init(id: String, synthetic: Bool = false) {
        self.id = id
        self.synthetic = synthetic
    }
}

struct RawEvent: Sendable {
    let source: SourceContext
    let timestamp: UInt64
    let count: Int
    let a: UInt32
    let b: UInt32
    let c: UInt32
    let d: UInt32
    init(source: SourceContext, timestamp: UInt64, count: Int, a: UInt32, b: UInt32 = 0, c: UInt32 = 0, d: UInt32 = 0) {
        self.source = source
        self.timestamp = timestamp
        self.count = count
        self.a = a
        self.b = b
        self.c = c
        self.d = d
    }
    var message: MIDIMessage? { MIDIMessage(words: Array([a, b, c, d].prefix(count)), timestamp: timestamp) }
}

final class MIDIInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RawEvent?]
    private var head = 0
    private var count = 0
    private var accepting = false
    private var suspended: Set<String> = []
    private var overflows: Set<String> = []
    init(capacity: Int) {
        precondition(capacity > 0)
        storage = Array(repeating: nil, count: capacity)
    }
    func setAccepting(_ value: Bool) { lock.withLock { accepting = value } }
    @discardableResult func push(_ event: RawEvent) -> Bool {
        lock.withLock {
            guard accepting, !suspended.contains(event.source.id) else { return false }
            guard count < storage.count else {
                suspended.insert(event.source.id)
                overflows.insert(event.source.id)
                return false
            }
            storage[(head + count) % storage.count] = event
            count += 1
            return true
        }
    }
    func suspend(_ id: String) { _ = lock.withLock { suspended.insert(id) } }
    func isSuspended(_ id: String) -> Bool { lock.withLock { suspended.contains(id) } }
    func take(limit: Int) -> (events: [RawEvent], overflows: Set<String>, remaining: Bool) {
        lock.withLock {
            let faults = overflows
            overflows = []
            var events: [RawEvent] = []
            events.reserveCapacity(min(limit, count))
            for _ in 0..<min(limit, count) {
                if let event = storage[head] { events.append(event) }
                storage[head] = nil
                head = (head + 1) % storage.count
                count -= 1
            }
            return (events, faults, count > 0)
        }
    }
    func reset(accepting: Bool) {
        lock.withLock {
            for index in storage.indices { storage[index] = nil }
            head = 0
            count = 0
            suspended = []
            overflows = []
            self.accepting = accepting
        }
    }
}
