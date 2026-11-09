import Foundation
import XCTest

@testable import MIDIRouterApp

final class CableLabelTests: XCTestCase {
    private let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testWireHitRegionFollowsCurveRatherThanItsBoundingBox() {
        let curve = CableCurve(start: CGPoint(x: 100, y: 80), end: CGPoint(x: 900, y: 280))
        XCTAssertTrue(curve.contains(curve.midpoint))
        XCTAssertTrue(curve.contains(CGPoint(x: 500, y: 185)))
        XCTAssertFalse(curve.contains(CGPoint(x: 500, y: 230)))
        XCTAssertFalse(curve.contains(CGPoint(x: 100, y: 280)))
    }

    func testUnobstructedLabelStaysAtCurveMidpoint() throws {
        let curve = CableCurve(start: CGPoint(x: 100, y: 80), end: CGPoint(x: 900, y: 280))
        XCTAssertEqual(curve.point(at: 0), curve.start)
        XCTAssertEqual(curve.point(at: 1), curve.end)
        XCTAssertEqual(curve.midpoint, CGPoint(x: 500, y: 180))
        let label = CableLabel(id: first, anchor: curve.midpoint, size: CGSize(width: 70, height: 28))
        let placement = try XCTUnwrap(CableLabelLayout.place([label])[first])
        XCTAssertEqual(placement.center, curve.midpoint)
        XCTAssertFalse(placement.displaced)
    }

    func testUnrelatedLabelsDoNotMoveAndRouteOrderDoesNotMatter() {
        let labels = [
            CableLabel(id: first, anchor: CGPoint(x: 500, y: 180), size: CGSize(width: 70, height: 28)),
            CableLabel(id: second, anchor: CGPoint(x: 500, y: 300), size: CGSize(width: 70, height: 28)),
        ]
        let positions = CableLabelLayout.place(labels)
        XCTAssertEqual(positions[first]?.center, labels[0].anchor)
        XCTAssertEqual(positions[second]?.center, labels[1].anchor)
        XCTAssertEqual(positions, CableLabelLayout.place(Array(labels.reversed())))
    }

    func testOverlappingLabelsSeparateButKeepTheirCurveAnchors() throws {
        let anchor = CGPoint(x: 400, y: 160)
        let labels = [first, second].map {
            CableLabel(id: $0, anchor: anchor, size: CGSize(width: 100, height: 28))
        }
        let positions = CableLabelLayout.place(labels)
        let a = try XCTUnwrap(positions[first])
        let b = try XCTUnwrap(positions[second])
        XCTAssertEqual(a.center, anchor)
        XCTAssertTrue(b.displaced)
        XCTAssertEqual(b.anchor, anchor)
        XCTAssertFalse(a.frame.intersects(b.frame))
        XCTAssertEqual(positions, CableLabelLayout.place(Array(labels.reversed())))
    }

    func testMeasuredLabelSizesAndDeviceBoxesAreRespected() throws {
        let box = CGRect(x: 300, y: 80, width: 200, height: 300)
        let labels = [
            CableLabel(id: first, anchor: CGPoint(x: 400, y: 180), size: CGSize(width: 240, height: 64)),
            CableLabel(id: second, anchor: CGPoint(x: 400, y: 180), size: CGSize(width: 130, height: 40)),
        ]
        let positions = CableLabelLayout.place(labels, obstacles: [box])
        let a = try XCTUnwrap(positions[first])
        let b = try XCTUnwrap(positions[second])
        XCTAssertFalse(a.frame.intersects(box))
        XCTAssertFalse(b.frame.intersects(box))
        XCTAssertFalse(a.frame.intersects(b.frame))
        XCTAssertGreaterThanOrEqual(a.frame.minY, 0)
        XCTAssertGreaterThanOrEqual(b.frame.minY, 0)
    }

    func testCrowdedFallbackRemainsFiniteAndOutsideObstacles() {
        let labels = (1...16).map { index in
            CableLabel(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                anchor: CGPoint(x: 150, y: 80), size: CGSize(width: 120, height: 28))
        }
        let obstacle = CGRect(x: 0, y: 0, width: 300, height: 10_000)
        let positions = CableLabelLayout.place(labels, obstacles: [obstacle]).values.sorted {
            $0.center.y < $1.center.y
        }
        XCTAssertEqual(positions.count, labels.count)
        for (index, position) in positions.enumerated() {
            XCTAssertTrue(position.center.y.isFinite)
            XCTAssertFalse(position.frame.intersects(obstacle))
            for previous in positions.prefix(index) { XCTAssertFalse(position.frame.intersects(previous.frame)) }
        }
    }
}
