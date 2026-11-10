import Foundation
import RouterCore
import XCTest

@testable import MIDIRouterApp

@MainActor
final class PresentationNamesTests: XCTestCase {
    func testPrimaryPagesMatchVisibleShortcutOrder() {
        XCTAssertEqual(AppState.Page.primary, [.routes, .presets, .devices])
        XCTAssertFalse(AppState.Page.primary.contains(.monitor))
    }

    func testRouteListNamePreservesStoredRoomIdentifier() throws {
        XCTAssertEqual(Room.terminal.displayName, "Route List")
        XCTAssertEqual(Room.studio.displayName, "Studio")
        XCTAssertEqual(Room.desktop.displayName, "Desktop")
        XCTAssertEqual(Room.glass.displayName, "Glass")
        let stored = try JSONEncoder().encode(Room.terminal)
        XCTAssertEqual(String(decoding: stored, as: UTF8.self), "\"terminal\"")
        XCTAssertEqual(try JSONDecoder().decode(Room.self, from: stored), .terminal)
    }
}
