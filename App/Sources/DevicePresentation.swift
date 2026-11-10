import Darwin
import Foundation
import RouterCore

extension Room {
    var displayName: String { self == .terminal ? "Route List" : rawValue.capitalized }
}

struct DeviceVisibility {
    private var offlineSince: [String: ContinuousClock.Instant] = [:]
    private var previouslyOnline: Set<String> = []
    static let grace: Duration = .seconds(30)

    mutating func update(known: Set<String>, online: Set<String>, now: ContinuousClock.Instant) -> Set<String> {
        offlineSince = offlineSince.filter { known.contains($0.key) && !online.contains($0.key) }
        for id in previouslyOnline.subtracting(online).intersection(known) { offlineSince[id] = now }
        previouslyOnline = online.intersection(known)
        return Set(
            known.filter { id in
                online.contains(id) || offlineSince[id].map { now < $0.advanced(by: Self.grace) } ?? false
            })
    }
}

enum SignalActivity {
    static let holdSeconds = 0.7
    static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? 0 : Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
    static func isRecent(_ lastEvent: UInt64?, now: UInt64, secondsPerTick: Double) -> Bool {
        guard let lastEvent, lastEvent <= now, secondsPerTick > 0, secondsPerTick.isFinite else { return false }
        return Double(now - lastEvent) * secondsPerTick < holdSeconds
    }
    static func isReceiving(_ port: RouterPort, online: Bool, lastEvent: UInt64?, now: UInt64, secondsPerTick: Double)
        -> Bool
    {
        port.direction == .input && online && isRecent(lastEvent, now: now, secondsPerTick: secondsPerTick)
    }
}
