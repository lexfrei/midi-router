import AppKit
import RouterCore
import SwiftUI
import XCTest

@testable import MIDIRouterApp

@MainActor
final class PickerRenderingTests: XCTestCase {
    func testOrdinaryValuesUseASCIIPopupAndCommitSelection() throws {
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        var selection = "first"
        let picker = PopupPicker(
            "Input", state: state, selection: Binding(get: { selection }, set: { selection = $0 }),
            options: [PopupChoice(value: "first", title: "Input [A]"), PopupChoice(value: "second", title: "Input B")])
        try render(picker) { host in
            let button = try XCTUnwrap(buttons(in: host).first)
            XCTAssertFalse(button is NSPopUpButton)
            button.performClick(nil)
            XCTAssertEqual(state.popupMenu?.items.compactMap { $0 }.map(\.title), ["Input [A]", "Input B"])
            XCTAssertEqual(state.popupMenu?.items.compactMap { $0 }.map(\.selected), [true, false])
            state.activatePopup(index: 1)
            XCTAssertEqual(selection, "second")
        }
    }

    func testOptionalValuesAndDisabledChoicesPreserveSelection() throws {
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        var selection: Int?
        let picker = PopupPicker(
            "Channel", state: state, selection: Binding(get: { selection }, set: { selection = $0 }),
            options: [
                PopupChoice(value: nil as Int?, title: "AUTO"),
                PopupChoice(value: Optional(1), title: "CH 1", enabled: false),
                PopupChoice(value: Optional(2), title: "CH 2"),
            ])
        try render(picker) { host in
            let button = try XCTUnwrap(buttons(in: host).first)
            button.performClick(nil)
            XCTAssertEqual(state.popupMenu?.items.compactMap { $0 }.map(\.enabled), [true, false, true])
            state.activatePopup(index: 1)
            XCTAssertNil(selection)
            state.activatePopup(index: 2)
            XCTAssertEqual(selection, 2)
            button.performClick(nil)
            state.activatePopup(index: 0)
            XCTAssertNil(selection)
        }
    }

    func testSingleEnabledChoiceIsReadOnlyInsteadOfPopup() throws {
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        for options in [
            [PopupChoice(value: 1, title: "Only Input")],
            [PopupChoice(value: 1, title: "Only Input"), PopupChoice(value: 2, title: "Unavailable", enabled: false)],
        ] {
            render(PopupPicker("Input", state: state, selection: .constant(1), options: options)) { host in
                XCTAssertTrue(buttons(in: host).isEmpty)
                XCTAssertNil(state.popupMenu)
            }
        }
    }

    private func render<Content: View>(_ view: Content, check: (NSHostingView<Content>) throws -> Void) rethrows {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
        try check(host)
        XCTAssertFalse(window.isVisible)
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
}
