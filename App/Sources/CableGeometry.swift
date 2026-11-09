import SwiftUI

struct CableCurve {
    let start: CGPoint
    let end: CGPoint
    private var bend: Double { max(60, abs(end.x - start.x) * 0.45) }
    var midpoint: CGPoint { point(at: 0.5) }
    var path: Path {
        Path { path in
            path.move(to: start)
            path.addCurve(
                to: end, control1: CGPoint(x: start.x + bend, y: start.y),
                control2: CGPoint(x: end.x - bend, y: end.y))
        }
    }
    func contains(_ point: CGPoint) -> Bool {
        path.cgPath.copy(strokingWithWidth: 20, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(point)
    }
    func point(at t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * u * start.x + 3 * u * u * t * (start.x + bend)
                + 3 * u * t * t * (end.x - bend) + t * t * t * end.x,
            y: u * u * u * start.y + 3 * u * u * t * start.y
                + 3 * u * t * t * end.y + t * t * t * end.y)
    }
}

struct CableLabel {
    let id: UUID
    let anchor: CGPoint
    let size: CGSize
}

struct CableLabelPlacement: Equatable {
    let anchor: CGPoint
    let center: CGPoint
    let size: CGSize
    var displaced: Bool { center != anchor }
    var frame: CGRect {
        CGRect(
            x: center.x - size.width / 2, y: center.y - size.height / 2,
            width: size.width, height: size.height)
    }
}

enum CableLabelLayout {
    static func place(_ labels: [CableLabel], obstacles: [CGRect] = []) -> [UUID: CableLabelPlacement] {
        var occupied = obstacles
        var placements: [UUID: CableLabelPlacement] = [:]
        for label in labels.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            let size = CGSize(width: max(1, label.size.width), height: max(1, label.size.height))
            func available(_ center: CGPoint) -> Bool {
                let frame = CableLabelPlacement(anchor: label.anchor, center: center, size: size).frame
                return frame.minY >= 0 && !occupied.contains { $0.intersects(frame.insetBy(dx: -4, dy: -4)) }
            }
            var center = label.anchor
            if !available(center) {
                var alternative: CGPoint?
                for row in 1...(labels.count + obstacles.count + 1) {
                    for direction in [1.0, -1.0] {
                        let candidate = CGPoint(
                            x: label.anchor.x,
                            y: label.anchor.y + direction * Double(row) * (size.height + 8))
                        if available(candidate) {
                            alternative = candidate
                            break
                        }
                    }
                    if alternative != nil { break }
                }
                let bottom = max(0, label.anchor.y, occupied.map(\.maxY).max() ?? 0)
                center = alternative ?? CGPoint(x: label.anchor.x, y: bottom + size.height / 2 + 8)
            }
            let placement = CableLabelPlacement(anchor: label.anchor, center: center, size: size)
            placements[label.id] = placement
            occupied.append(placement.frame)
        }
        return placements
    }
}

struct RouteLabelSizes: PreferenceKey {
    static var defaultValue: [UUID: CGSize] { [:] }
    static func reduce(value: inout [UUID: CGSize], nextValue: () -> [UUID: CGSize]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}
