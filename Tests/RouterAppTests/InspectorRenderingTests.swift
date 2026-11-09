import AppKit
import RouterCore
import SwiftUI
import XCTest

@testable import MIDIRouterApp

@MainActor
final class InspectorRenderingTests: XCTestCase {
    func testInspectorRendersInsideHiddenWindowWithoutCompressingTranspose() throws {
        _ = NSApplication.shared
        let keyWindow = NSApp.keyWindow
        for (scale, width) in [(1.0, 640.0), (2.0, 880.0)] {
            let route = Route(source: "in", destination: "out", transpose: -12)
            let setup = Setup(
                ports: [
                    RouterPort(id: "in", name: "Input A", direction: .input),
                    RouterPort(id: "out", name: "Output B", direction: .output),
                ], routes: [route])
            let preset = Preset(name: "Saved Setup", setup: setup)
            let session = Session(setup: setup, presets: [preset], textScale: scale)
            let state = AppState(initial: session, startEngine: false, persist: false)
            state.showOfflineDevices = true
            let host = NSHostingView(
                rootView: ContentView(state: state).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: width, height: 720),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            defer { window.close() }
            host.frame = CGRect(x: 0, y: 0, width: width, height: 720)
            let cases: [(String, () -> Void, String)] = [
                ("route", { state.inspectRoute(route.id) }, "-12"),
                ("new-route", { state.beginNewRoute() }, "0"),
                ("device", { state.inspectPort("in") }, ""),
                ("preset", { state.inspectPreset(preset.id) }, "Saved Setup"),
                ("new-preset", { state.beginNewPreset() }, "New Setup"),
            ]
            for (name, open, value) in cases {
                if name == "new-preset" { state.page = .presets }
                settle(host)
                let pageScroll = try XCTUnwrap(scrollViews(in: host).first)
                let viewport = pageScroll.convert(pageScroll.bounds, to: host)
                let page = state.page
                open()
                settle(host)
                let field = try XCTUnwrap(textFields(in: host).first { $0.isEditable && $0.stringValue == value })
                XCTAssertGreaterThanOrEqual(field.frame.width, 70 * scale)
                XCTAssertTrue(host.bounds.contains(field.convert(field.bounds, to: host)))
                XCTAssertEqual(state.page, page)
                XCTAssertEqual(pageScroll.convert(pageScroll.bounds, to: host), viewport)
                let panelScroll = try XCTUnwrap(scrollViews(in: host).first { $0 !== pageScroll })
                XCTAssertTrue(host.bounds.contains(panelScroll.convert(panelScroll.bounds, to: host)))
                XCTAssertFalse(window.isVisible)
                XCTAssertTrue(window.sheets.isEmpty)
                XCTAssertTrue(NSApp.keyWindow === keyWindow)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()
                let folder = root.appendingPathComponent(".build/inspector-previews")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try png.write(to: folder.appendingPathComponent("\(name)-\(Int(scale)).png"))
                state.closeInspector()
                settle(host)
                XCTAssertNil(state.inspector)
                XCTAssertFalse(window.isVisible)
            }
        }
    }
    func testInspectorDoesNotResizeOrScrollPatchbay() throws {
        _ = NSApplication.shared
        let keyWindow = NSApp.keyWindow
        for room in [Room.studio, .glass, .desktop] {
            for (scale, width) in [(1.0, 1100.0), (1.0, 640.0), (2.0, 880.0)] {
                let ports = (0..<8).flatMap { index in
                    [
                        RouterPort(id: "in-\(index)", name: "Input \(index)", direction: .input),
                        RouterPort(id: "out-\(index)", name: "Output \(index)", direction: .output),
                    ]
                }
                let routes = (0..<2).map { Route(source: "in-\($0)", destination: "out-\($0)") }
                let setup = Setup(ports: ports, routes: routes)
                let preset = Preset(name: "Saved Setup", setup: setup)
                let state = AppState(
                    initial: Session(setup: setup, presets: [preset], room: room, textScale: scale),
                    startEngine: false, persist: false)
                state.showOfflineDevices = true
                let host = NSHostingView(
                    rootView: ContentView(state: state).background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: width, height: 720),
                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                settle(host)
                let scroll = try XCTUnwrap(scrollViews(in: host).first)
                let document = try XCTUnwrap(scroll.documentView)
                scroll.contentView.scroll(to: CGPoint(x: scale > 1 ? 40 : 0, y: 60))
                scroll.reflectScrolledClipView(scroll.contentView)
                settle(host)
                let viewport = scroll.convert(scroll.bounds, to: host)
                let content = document.frame
                let visible = scroll.contentView.bounds
                XCTAssertGreaterThan(visible.origin.y, 0)
                let changes: [() -> Void] = [
                    { state.inspectRoute(routes[0].id) },
                    { state.inspectRoute(routes[1].id) },
                    { state.inspectPort(ports[0].id) },
                    { state.inspectPreset(preset.id) },
                    { state.beginNewRoute() },
                    { state.beginNewPreset() },
                    { state.closeInspector() },
                    { state.inspectRoute(routes[0].id) },
                    { state.clearSelection() },
                ]
                for change in changes {
                    change()
                    settle(host)
                    XCTAssertTrue(scroll.isDescendant(of: host))
                    XCTAssertEqual(scroll.convert(scroll.bounds, to: host), viewport)
                    XCTAssertEqual(document.frame, content)
                    XCTAssertEqual(scroll.contentView.bounds, visible)
                    XCTAssertFalse(window.isVisible)
                    XCTAssertTrue(window.sheets.isEmpty)
                    XCTAssertTrue(NSApp.keyWindow === keyWindow)
                }
            }
        }
    }
    private func settle(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        view.layoutSubtreeIfNeeded()
    }
    private func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    private func textFields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
    }
}
