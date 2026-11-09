import Foundation
import RouterCore
import XCTest

@testable import MIDIRouterApp

final class LayoutTests: XCTestCase {
    func testExpandedPortSlotsNeverOverlapFollowingNodes() {
        let ports = [
            RouterPort(
                id: "a", name: "A", direction: .input,
                slots: (1...16).map { Slot(name: "CH \($0)", channel: $0) }),
            RouterPort(id: "b", name: "B", direction: .input),
            RouterPort(id: "c", name: "C", direction: .output),
        ]
        let layout = PatchLayout(ports: ports, room: .studio, width: 1000, scale: 2)
        XCTAssertLessThan(layout.frames["a"]!.maxY, layout.frames["b"]!.minY)
        XCTAssertGreaterThanOrEqual(layout.size.height, layout.frames["b"]!.maxY)
        XCTAssertGreaterThan(layout.frames["c"]!.minX, layout.frames["a"]!.maxX)
    }
    func testDesktopPositionAndHiddenPorts() {
        let ports = [
            RouterPort(id: "a", name: "A", direction: .input, position: Position(x: 900, y: 500)),
            RouterPort(id: "b", name: "B", direction: .output, hidden: true),
        ]
        let layout = PatchLayout(ports: ports, room: .desktop, width: 1000, scale: 1)
        XCTAssertEqual(layout.frames["a"]?.origin, CGPoint(x: 900, y: 500))
        XCTAssertNil(layout.frames["b"])
        XCTAssertGreaterThan(layout.size.width, layout.frames["a"]!.maxX)
    }
    func testDropTargetUsesOutputSocketAndKeepsFanOut() throws {
        let ports = [
            RouterPort(id: "in", name: "Keys", direction: .input),
            RouterPort(id: "a", name: "A", direction: .output),
            RouterPort(id: "b", name: "B", direction: .output),
        ]
        let layout = PatchLayout(ports: ports, room: .studio, width: 1000, scale: 1)
        let point = try XCTUnwrap(layout.anchor(port: ports[1], slot: nil))
        XCTAssertEqual(layout.dropTarget(at: point, ports: ports)?.port, "a")
        XCTAssertNil(layout.dropTarget(at: CGPoint(x: 500, y: 400), ports: ports))
        XCTAssertNil(layout.dropTarget(at: layout.anchor(port: ports[0], slot: nil)!, ports: ports))
    }

}
