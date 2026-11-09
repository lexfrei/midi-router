import AppKit
import RouterCore
import SwiftUI
import XCTest

@testable import MIDIRouterApp

@MainActor
final class PopupRenderingTests: XCTestCase {
    func testInspectorAndPickerStayNearTheirAnchorsInBothAppearances() throws {
        _ = NSApplication.shared
        let keyWindow = NSApp.keyWindow
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (scale, width) in [(1.0, 1100.0), (2.0, 880.0)] {
                let route = Route(source: "in", destination: "out")
                let ports = [
                    RouterPort(id: "in", name: "Input A", direction: .input),
                    RouterPort(id: "other", name: "Another Controller", direction: .input),
                    RouterPort(id: "out", name: "Output", direction: .output),
                ]
                let state = AppState(
                    initial: Session(setup: Setup(ports: ports, routes: [route]), textScale: scale), startEngine: false,
                    persist: false)
                state.showOfflineDevices = true
                let host = NSHostingView(
                    rootView: ContentView(state: state).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(
                    contentRect: CGRect(x: 0, y: 0, width: width, height: 720), styleMask: [.titled, .resizable],
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = host
                defer { window.close() }
                settle(host)
                for x in [200.0, width - 40] {
                    let origin = CGRect(x: x, y: 240, width: 0, height: 0)
                    state.inspectRoute(route.id, origin: origin)
                    settle(host)
                    let panel = try XCTUnwrap(state.popupAnchors["inspector-panel"])
                    XCTAssertTrue(host.bounds.contains(panel))
                    if x == 200 { XCTAssertEqual(panel.minX, x + 8) } else { XCTAssertEqual(panel.maxX, x - 8) }
                }
                let inspectorFrame = try XCTUnwrap(state.popupAnchors["inspector-panel"])
                let input = try XCTUnwrap(state.popupAnchors["route-input"])
                let button = try XCTUnwrap(
                    buttons(in: host).first {
                        let frame = $0.convert($0.bounds, to: host)
                        return input.insetBy(dx: -1, dy: -1).contains(frame)
                            && frame.insetBy(dx: -1, dy: -1).contains(input)
                    })
                button.performClick(nil)
                settle(host)
                XCTAssertEqual(state.popupMenu?.label, "Input")
                XCTAssertEqual(state.popupMenu?.anchor, input)
                let menuFrame = try XCTUnwrap(state.popupAnchors["popup-panel"])
                XCTAssertTrue(host.bounds.contains(menuFrame))
                let font = NSFont.monospacedSystemFont(ofSize: 13 * scale, weight: .regular)
                let longest = try XCTUnwrap(
                    state.popupMenu?.items.compactMap { $0 }.map {
                        ($0.title as NSString).size(withAttributes: [.font: font]).width
                    }.max())
                let markers = (">*" as NSString).size(withAttributes: [.font: font]).width
                XCTAssertGreaterThanOrEqual(menuFrame.width, longest + markers + 48)
                XCTAssertEqual(state.popupAnchors["inspector-panel"], inspectorFrame)
                XCTAssertTrue(buttons(in: host).compactMap { $0 as? NSPopUpButton }.isEmpty)
                XCTAssertFalse(window.isVisible)
                XCTAssertTrue(window.sheets.isEmpty)
                XCTAssertTrue(NSApp.keyWindow === keyWindow)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()
                let folder = root.appendingPathComponent(".build/popup-previews")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: folder.appendingPathComponent("input-\(appearance.rawValue)-\(Int(scale)).png"))
                state.activatePopup(index: 1)
                XCTAssertEqual(state.session.setup.routes[0].source, "other")
                XCTAssertNil(state.popupMenu)
                XCTAssertEqual(state.inspectorOrigin?.minX, width - 40)
            }
        }
    }

    func testRebindingDeviceKeepsInspectorAnchor() throws {
        _ = NSApplication.shared
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        state.setDemo(true)
        defer { state.stop() }
        state.edit("Add Offline Device") {
            $0.setup.ports.append(RouterPort(id: "offline", name: "Offline", direction: .output))
        }
        let origin = CGRect(x: 200, y: 200, width: 0, height: 0)
        state.inspectPort("offline", origin: origin)
        let host = NSHostingView(rootView: ContentView(state: state))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1100, height: 720), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        settle(host)
        let anchor = try XCTUnwrap(state.popupAnchors["rebind-offline"])
        let button = try XCTUnwrap(
            buttons(in: host).first {
                let frame = $0.convert($0.bounds, to: host)
                return anchor.insetBy(dx: -1, dy: -1).contains(frame) && frame.insetBy(dx: -1, dy: -1).contains(anchor)
            })
        button.performClick(nil)
        state.activatePopup(index: 0)
        XCTAssertEqual(state.inspector, .port("demo:output"))
        XCTAssertEqual(state.inspectorOrigin, origin)
        XCTAssertFalse(window.isVisible)
    }

    func testSoleAvailableOptionCanReplaceMissingSelection() throws {
        _ = NSApplication.shared
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        var value = "missing"
        let picker = PopupPicker(
            "Input", state: state, selection: Binding(get: { value }, set: { value = $0 }),
            options: [PopupChoice(value: "online", title: "Input")])
        let host = NSHostingView(rootView: picker)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 80), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        settle(host)
        try XCTUnwrap(buttons(in: host).first).performClick(nil)
        state.activatePopup()
        XCTAssertEqual(value, "online")
        XCTAssertFalse(window.isVisible)
    }

    func testLongMenuScrollsKeyboardSelectionIntoView() throws {
        _ = NSApplication.shared
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        let host = NSHostingView(rootView: ContentView(state: state))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 460), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        var selected: Int?
        settle(host)
        state.showPopup(
            source: "programs", label: "Program",
            items: (0...127).map { index in
                PopupItem(title: String(index)) { selected = index }
            }, origin: CGRect(x: 600, y: 400, width: 0, height: 0))
        settle(host)
        state.searchPopup("127", now: 1)
        settle(host)
        XCTAssertEqual(state.popupMenu?.highlighted, 127)
        let frame = try XCTUnwrap(state.popupAnchors["popup-panel"])
        XCTAssertTrue(host.bounds.contains(frame))
        let scroll = try XCTUnwrap(scrolls(in: host).first { frame.contains($0.convert($0.bounds, to: host)) })
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        state.activatePopup()
        XCTAssertEqual(selected, 127)
        XCTAssertNil(state.popupMenu)
        XCTAssertFalse(window.isVisible)
    }

    private func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        host.layoutSubtreeIfNeeded()
    }
    private func buttons(in view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
    }
    private func scrolls(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls(in: $0) }
    }
}
