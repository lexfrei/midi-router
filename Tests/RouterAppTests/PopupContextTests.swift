import AppKit
import XCTest

@testable import MIDIRouterApp

@MainActor
final class PopupContextTests: XCTestCase {
    func testContextTargetAcceptsOnlySecondaryAndControlClicks() throws {
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1))
        }
        XCTAssertTrue(PopupContextView.accepts(try event(.rightMouseDown)))
        XCTAssertTrue(PopupContextView.accepts(try event(.leftMouseDown, .control)))
        XCTAssertFalse(PopupContextView.accepts(try event(.leftMouseDown)))
        XCTAssertFalse(PopupContextView.accepts(try event(.leftMouseDragged)))
        XCTAssertFalse(PopupContextView.accepts(nil))
    }
}
