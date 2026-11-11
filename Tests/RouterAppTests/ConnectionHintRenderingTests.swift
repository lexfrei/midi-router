import AppKit
import RouterCore
import SwiftUI
import XCTest

@testable import MIDIRouterApp

@MainActor
final class ConnectionHintRenderingTests: XCTestCase {
    func testHintDisappearsWithAnyRouteAndReturnsAfterRemovingTheLastRoute() throws {
        _ = NSApplication.shared
        let setup = Setup(ports: [
            RouterPort(id: "in", name: "Input", direction: .input),
            RouterPort(id: "out", name: "Output", direction: .output),
        ])
        let state = AppState(initial: Session(setup: setup), startEngine: false, persist: false)
        state.showOfflineDevices = true
        let host = NSHostingView(rootView: ContentView(state: state))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }

        func anchor(in room: Room) throws -> CGRect {
            state.changeRoom(room)
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            host.layoutSubtreeIfNeeded()
            return try XCTUnwrap(state.popupAnchors["connector-in-main"])
        }
        func assertHintVisible(_ visible: Bool, file: StaticString = #filePath, line: UInt = #line) throws {
            let studio = try anchor(in: .studio)
            let glass = try anchor(in: .glass)
            if visible {
                XCTAssertGreaterThan(glass.minY, studio.minY, file: file, line: line)
            } else {
                XCTAssertEqual(glass, studio, file: file, line: line)
            }
        }

        try assertHintVisible(true)
        let disabled = Route(source: "in", destination: "out", enabled: false)
        state.addRoute(disabled)
        try assertHintVisible(false)
        let enabled = Route(source: "in", destination: "out", channel: 2)
        state.addRoute(enabled)
        try assertHintVisible(false)
        state.removeRoute(enabled.id)
        try assertHintVisible(false)
        state.removeRoute(disabled.id)
        try assertHintVisible(true)
        XCTAssertFalse(window.isVisible)
    }
}
