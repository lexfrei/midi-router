import Foundation

// SysEx7 streams directly; Flex buffers its spec-bounded 32 UMPs. Musical events never wait.
// ponytail: 128 active transfers, no payload accumulation outside Flex; discovery can refine receiver limits.
struct MultipartRouting: Sendable {
    private struct Key: Hashable {
        var source: String
        var group: UInt8
        var kind: UInt32
        var id: UInt32
    }
    private struct Target: Sendable {
        var delivery: Delivery
        var id: UInt32
    }
    private struct Transfer: Sendable {
        var targets: [Target]
        var packets: [MIDIMessage] = []
        var lastActivity: TimeInterval
        var remaining = 0
        var chunk: UInt32 = 0
        var final = false
        var flexIdentity: UInt32 = 0
    }
    private var transfers: [Key: Transfer] = [:]
    var diagnostics: [String] = []

    static func handles(_ message: MIDIMessage) -> Bool {
        (message.type == 3 && message.status >> 4 <= 3) || message.type == 13
            || (message.type == 5 && [0, 1, 2, 3, 8, 9].contains((message.words[0] >> 20) & 15))
    }

    private func key(_ message: MIDIMessage, source: String) -> Key {
        let form = (message.words[0] >> 20) & 15
        let kind: UInt32 = message.type == 5 && form >= 8 ? 8 : message.type
        let id = kind == 8 ? (message.words[0] >> 16) & 15 : kind == 5 ? (message.words[0] >> 8) & 255 : 0
        return Key(source: source, group: message.group, kind: kind, id: id)
    }

    mutating func receive(
        _ message: MIDIMessage, source: String, candidates: [Delivery], now: TimeInterval,
        canDeliver: (String) -> Bool
    ) -> [Delivery] {
        let key = key(message, source: source)
        let form = message.type == 13 ? (message.words[0] >> 22) & 3 : (message.words[0] >> 20) & 15
        let starts = key.kind == 8 ? form == 8 && message.words[1] & 0xFFFF == 1 : form <= 1
        var output: [Delivery] = []
        if starts {
            if let previous = transfers.removeValue(forKey: key) {
                output += abort(key, transfer: previous, timestamp: message.timestamp).filter {
                    canDeliver($0.destination)
                }
                warn("Multipart transfer replaced before completion.")
            }
            guard transfers.count < 128 else {
                warn("Multipart transfer limit reached; transfer dropped.")
                return output
            }
            var targets: [Target] = []
            for delivery in candidates {
                let used = transfers.filter {
                    if key.kind == 5 { return $0.key.kind == 5 }
                    if key.kind == 3 || key.kind == 13 {
                        return $0.key.group == key.group && ($0.key.kind == 3 || $0.key.kind == 13)
                    }
                    return $0.key.group == key.group && $0.key.kind == key.kind
                }
                .values.flatMap(\.targets).filter { $0.delivery.destination == delivery.destination }.map(\.id)
                if key.kind == 5 {
                    // UMP §7.8 requires receiver discovery before using simultaneous SysEx8 streams.
                    guard used.isEmpty else {
                        warn("SysEx8 destination is busy; transfer dropped (receiver stream capacity is unknown).")
                        continue
                    }
                    targets.append(Target(delivery: delivery, id: 0))
                } else if key.kind == 8 {
                    guard let id = (UInt32(0)...15).first(where: { !used.contains($0) }) else {
                        warn("All destination MDS IDs are in use; transfer dropped.")
                        continue
                    }
                    targets.append(Target(delivery: delivery, id: id))
                } else {
                    guard used.isEmpty else {
                        warn("Destination group has an active SysEx7 or Flex transfer; competing transfer dropped.")
                        continue
                    }
                    targets.append(Target(delivery: delivery, id: 0))
                }
            }
            guard !targets.isEmpty else { return output }
            transfers[key] = Transfer(targets: targets, lastActivity: now, flexIdentity: message.words[0] & 0x003F_FFFF)
        }
        guard var transfer = transfers[key] else {
            warn("Multipart fragment without an admitted start dropped.")
            return output
        }
        let lost = transfer.targets.filter { !canDeliver($0.delivery.destination) }
        if !lost.isEmpty { warn("Multipart destination became unavailable; transfer dropped for that destination.") }
        transfer.targets.removeAll { !canDeliver($0.delivery.destination) }
        guard !transfer.targets.isEmpty else {
            transfers[key] = nil
            return output
        }
        transfer.lastActivity = now
        if key.kind == 13 {
            let limit = 32
            guard transfer.packets.count < limit,
                transfer.flexIdentity == message.words[0] & 0x003F_FFFF,
                form == 3 || transfer.packets.count < limit - 1 || form == 0
            else {
                transfers[key] = nil
                warn("Multipart message exceeded its packet limit or changed Flex identity; transfer dropped.")
                return output
            }
            transfer.packets.append(message)
            if form == 0 || form == 3 {
                for target in transfer.targets {
                    output += transfer.packets.map {
                        Delivery(
                            destination: target.delivery.destination,
                            message: $0.replacing(channel: target.delivery.message.channel),
                            routeID: target.delivery.routeID)
                    }
                }
                transfers[key] = nil
            } else {
                transfers[key] = transfer
            }
            return output
        }
        if key.kind == 8 {
            if form == 8 {
                let bytes = Int(message.words[0] & 0xFFFF)
                let chunk = message.words[1] & 0xFFFF
                guard transfer.remaining == 0, bytes >= 16,
                    chunk == 0 || chunk == transfer.chunk + 1,
                    chunk == 0 || message.words[1] >> 16 == 0 || chunk <= message.words[1] >> 16
                else {
                    transfers[key] = nil
                    warn("Invalid MDS chunk sequence; transfer aborted.")
                    return output + abort(key, transfer: transfer, timestamp: message.timestamp)
                }
                transfer.chunk = chunk
                transfer.remaining = (bytes - 16 + 13) / 14
                transfer.final = chunk == 0 || (message.words[1] >> 16 != 0 && chunk == message.words[1] >> 16)
            } else {
                guard transfer.remaining > 0 else {
                    transfers[key] = nil
                    warn("Unexpected MDS payload; transfer aborted.")
                    return output + abort(key, transfer: transfer, timestamp: message.timestamp)
                }
                transfer.remaining -= 1
            }
        }
        for target in transfer.targets {
            var words = message.words
            if key.kind == 8 { words[0] = (words[0] & ~0x000F_0000) | target.id << 16 }
            if key.kind == 5 { words[0] = (words[0] & ~0x0000_FF00) | target.id << 8 }
            output.append(
                Delivery(
                    destination: target.delivery.destination,
                    message: MIDIMessage(words: words, timestamp: message.timestamp)!, routeID: target.delivery.routeID)
            )
        }
        let complete =
            key.kind == 3 || key.kind == 5 ? form == 0 || form == 3 : transfer.final && transfer.remaining == 0
        transfers[key] = complete ? nil : transfer
        return output
    }

    mutating func interrupt(deliveries: [Delivery], source: String? = nil) {
        for delivery in deliveries {
            let message = delivery.message
            guard message.groupNumber != nil,
                !(message.type == 1 && message.status >= 0xF8)
            else { continue }
            for key in Array(transfers.keys) where key.kind == 3 && key.group == message.group {
                if message.type == 3 && key.source == source { continue }
                let before = transfers[key]!.targets.count
                transfers[key]!.targets.removeAll { $0.delivery.destination == delivery.destination }
                if transfers[key]!.targets.count != before {
                    warn("Outgoing message interrupted a SysEx7 transfer; remaining fragments suppressed.")
                }
                if transfers[key]!.targets.isEmpty { transfers[key] = nil }
            }
        }
    }

    mutating func expire(now: TimeInterval, timestamp: UInt64) -> [Delivery] {
        // Router checks inactivity on receive, not with a timer; active bulk streams have no duration cap.
        cancel(
            timestamp: timestamp, reason: "Multipart transfer expired on receive after 30 seconds without a fragment."
        ) {
            now - $0.lastActivity >= 30
        }
    }

    mutating func disconnect(source: String, timestamp: UInt64) -> [Delivery] {
        var output: [Delivery] = []
        for key in Array(transfers.keys) where key.source == source {
            let transfer = transfers.removeValue(forKey: key)!
            output += abort(key, transfer: transfer, timestamp: timestamp)
            warn("Source disconnected; multipart transfer aborted.")
        }
        return output
    }

    @discardableResult
    mutating func disconnect(destination: String, timestamp: UInt64 = 0) -> [Delivery] {
        var output: [Delivery] = []
        for key in Array(transfers.keys) {
            var retired = transfers[key]!
            retired.targets = retired.targets.filter { $0.delivery.destination == destination }
            if !retired.targets.isEmpty {
                output += abort(key, transfer: retired, timestamp: timestamp)
                warn("Destination removed; multipart transfer aborted for that destination.")
            }
            transfers[key]!.targets.removeAll { $0.delivery.destination == destination }
            if transfers[key]!.targets.isEmpty { transfers[key] = nil }
        }
        return output
    }

    mutating func panic(timestamp: UInt64) -> [Delivery] {
        cancel(timestamp: timestamp, reason: "Multipart transfer cancelled.") { _ in true }
    }

    private mutating func cancel(timestamp: UInt64, reason: String, matching: (Transfer) -> Bool) -> [Delivery] {
        var output: [Delivery] = []
        for key in Array(transfers.keys) where matching(transfers[key]!) {
            let transfer = transfers.removeValue(forKey: key)!
            output += abort(key, transfer: transfer, timestamp: timestamp)
            warn(reason)
        }
        return output
    }

    private func abort(_ key: Key, transfer: Transfer, timestamp: UInt64) -> [Delivery] {
        guard key.kind == 5 || key.kind == 8 else { return [] }
        return transfer.targets.compactMap { target in
            var words = target.delivery.message.words
            if key.kind == 5 {
                words = [0x503F_0000 | UInt32(key.group) << 24 | target.id << 8, 0, 0, 0]
            } else {
                words[0] = 0x5080_0010 | UInt32(key.group) << 24 | target.id << 16
                words[1] = 0
            }
            guard let message = MIDIMessage(words: words, timestamp: timestamp) else { return nil }
            return Delivery(
                destination: target.delivery.destination, message: message, routeID: target.delivery.routeID)
        }
    }

    private mutating func warn(_ text: String) {
        if diagnostics.count < 128 { diagnostics.append(text) }
    }
}
