import AppKit
import RouterCore
import SwiftUI
import XCTest

@testable import MIDIRouterApp

@MainActor
final class NavigationRenderingTests: XCTestCase {
    func testTabFramesStayFixedAcrossPages() throws {
        for (scale, width) in [(1.0, 640.0), (1.0, 1100.0), (2.0, 880.0)] {
            let state = AppState(initial: Session(textScale: scale), startEngine: false, persist: false)
            let host = NSHostingView(rootView: ContentView(state: state))
            let window = makeWindow(host: host, width: width)
            defer { window.close() }
            settle(host)
            let initial = try tabFrames(in: host)
            for page in AppState.Page.allCases + [.routes] {
                state.page = page
                settle(host)
                XCTAssertEqual(try tabFrames(in: host), initial, "Selected page: \(page.rawValue)")
                XCTAssertFalse(window.isVisible)
            }
        }
    }

    func testMonitorHasNoPrimaryTabAndKeepsNavigationAvailable() throws {
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        let host = NSHostingView(rootView: ContentView(state: state))
        let window = makeWindow(host: host, width: 1100)
        defer { window.close() }
        settle(host)
        let primary = try tabFrames(in: host)
        XCTAssertEqual(primary.count, 3)
        state.page = .monitor
        settle(host)
        XCTAssertEqual(try tabFrames(in: host), primary)
        XCTAssertFalse(window.isVisible)
    }

    func testRoutingControlsBelongToWindowContent() throws {
        for (scale, width) in [(1.0, 640.0), (2.0, 880.0)] {
            let state = AppState(initial: Session(textScale: scale), startEngine: false, persist: false)
            let host = NSHostingView(rootView: ContentView(state: state))
            let window = makeWindow(host: host, width: width)
            defer { window.close() }
            settle(host)
            let tabTop = try XCTUnwrap(tabFrames(in: host).first).minY
            let controls = buttons(in: host).filter { $0.convert($0.bounds, to: host).maxY <= tabTop }
            XCTAssertEqual(controls.count, 4)
            for control in controls {
                XCTAssertTrue(host.bounds.contains(control.convert(control.bounds, to: host)))
                XCTAssertFalse(control.isBordered)
                XCTAssertGreaterThanOrEqual(control.bounds.height, 28)
            }
            XCTAssertTrue(controls.compactMap { $0 as? NSPopUpButton }.isEmpty)
            XCTAssertNotNil(state.popupAnchors["room-picker"])
            XCTAssertNotNil(state.popupAnchors["preset-picker"])
            XCTAssertNil(window.toolbar)
            XCTAssertFalse(window.isVisible)
        }
    }

    func testHeaderMenusKeepActionsAndSelectionInsideWindow() throws {
        let preset = Preset(name: "Saved Setup", setup: Setup())
        let state = AppState(initial: Session(presets: [preset]), startEngine: false, persist: false)
        let host = NSHostingView(rootView: ContentView(state: state))
        let window = makeWindow(host: host, width: 1100)
        let keyWindow = NSApp.keyWindow
        defer { window.close() }
        settle(host)
        func open(_ id: String) throws -> PopupMenuState {
            let anchor = try XCTUnwrap(state.popupAnchors[id])
            let button = try XCTUnwrap(
                buttons(in: host).first {
                    let frame = $0.convert($0.bounds, to: host)
                    return anchor.contains(CGPoint(x: frame.midX, y: frame.midY))
                })
            button.performClick(nil)
            settle(host)
            let menu = try XCTUnwrap(state.popupMenu)
            XCTAssertEqual(menu.anchor, anchor)
            XCTAssertTrue(host.bounds.contains(try XCTUnwrap(state.popupAnchors["popup-panel"])))
            return menu
        }
        var room = try open("room-picker")
        XCTAssertEqual(room.items.compactMap { $0 }.filter(\.selected).map(\.title), ["Studio"])
        state.activatePopup(index: try XCTUnwrap(room.items.firstIndex { $0?.title == "Route List" }))
        XCTAssertEqual(state.session.room, .terminal)
        settle(host)
        room = try open("room-picker")
        XCTAssertEqual(room.items.compactMap { $0 }.filter(\.selected).map(\.title), ["Route List"])
        state.dismissPopup()
        settle(host)
        var presets = try open("preset-picker")
        state.activatePopup(index: try XCTUnwrap(presets.items.firstIndex { $0?.title == "Save Current Setup…" }))
        XCTAssertEqual(state.inspector, .newPreset)
        XCTAssertEqual(state.session.presets.count, 1)
        state.closeInspector()
        settle(host)
        presets = try open("preset-picker")
        state.activatePopup(index: try XCTUnwrap(presets.items.firstIndex { $0?.title == preset.name }))
        XCTAssertEqual(state.activePreset, preset.id)
        settle(host)
        presets = try open("preset-picker")
        XCTAssertEqual(presets.items.compactMap { $0 }.filter(\.selected).map(\.title), [preset.name])
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(NSApp.keyWindow === keyWindow)
    }

    private func makeWindow(host: NSView, width: Double) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 720),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return window
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        host.layoutSubtreeIfNeeded()
    }

    private func tabFrames(in host: NSView) throws -> [CGRect] {
        let frames = buttons(in: host).filter { !($0 is NSPopUpButton) }
            .map { $0.convert($0.bounds, to: host) }
        let rows = Dictionary(grouping: frames, by: \.midY).values.filter { $0.count == 3 }
        let row = rows.min { ($0.first?.minY ?? 0) < ($1.first?.minY ?? 0) }
        return try XCTUnwrap(row).sorted { $0.minX < $1.minX }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
}
