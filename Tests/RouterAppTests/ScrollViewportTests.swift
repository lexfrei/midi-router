import AppKit
import RouterCore
import SwiftUI
import XCTest

@testable import MIDIRouterApp
@testable import RouterMIDI

@MainActor
final class ScrollViewportTests: XCTestCase {
    func testPatchbayFitsAvailableWidthWithEitherScrollerStyle() throws {
        for room in [Room.studio, .glass] {
            for (width, scale) in [(1100.0, 1.0), (640.0, 1.0), (1400.0, 2.0)] {
                for style in [NSScroller.Style.legacy, .overlay] {
                    let state = makeState(room: room, scale: scale)
                    let (window, host, scroll) = try makeWindow(state: state, width: width, style: style)
                    defer { window.close() }
                    assertFits(scroll, context: "\(room) width=\(width) scale=\(scale) style=\(style.rawValue)")
                    XCTAssertGreaterThan(
                        try XCTUnwrap(scroll.documentView).frame.height, scroll.contentView.bounds.height)
                    XCTAssertTrue(host.bounds.width >= 640)
                    XCTAssertFalse(window.isVisible)
                }
            }
        }
    }

    func testMonitorColumnsFitWithoutDiscardingPacketFields() throws {
        for width in [640.0, 1100.0] {
            for scale in [1.0, 2.0] {
                for style in [NSScroller.Style.legacy, .overlay] {
                    let state = makeState(scale: scale)
                    state.page = .monitor
                    state.monitorPaused = false
                    state.editPort("in-0") { $0.alias = String(repeating: "Long input name ", count: 10) }
                    state.editPort("out-0") { $0.alias = String(repeating: "Long output name ", count: 10) }
                    let message = try XCTUnwrap(
                        MIDIMessage(
                            words: [0xF000_0000, 0x1234_5678, 0x90AB_CDEF, 0xFEDC_BA98], timestamp: .max))
                    let records = (0..<100).map {
                        MonitorRecord(id: UInt64($0), source: "in-0", destination: "out-0", message: message)
                    }
                    state.updateFromSnapshot(
                        EngineSnapshot(
                            session: state.session, online: [], records: records, totalMessages: 100,
                            droppedMonitorRecords: 0, fault: nil, activePreset: nil, activity: [:], diagnostics: []))
                    let (window, host, scroll) = try makeWindow(state: state, width: width, style: style)
                    defer { window.close() }
                    assertFits(scroll, context: "monitor width=\(width) scale=\(scale) style=\(style.rawValue)")
                    let table = try XCTUnwrap(scroll.documentView as? NSTableView)
                    XCTAssertEqual(
                        table.tableColumns.map(\.headerCell.stringValue),
                        [
                            "Source", "Destination", "GRP", "CH", "Message", "UMP", "Host Timestamp",
                        ])
                    XCTAssertTrue(table.tableColumns.allSatisfy { $0.width >= 40 })
                    XCTAssertGreaterThan(
                        table.rect(ofColumn: table.numberOfColumns - 1).maxX,
                        scroll.contentView.bounds.width * 0.9)
                    XCTAssertTrue(state.monitorText.contains(message.umpHex))
                    if width == 1100 {
                        window.setContentSize(CGSize(width: 640, height: 720))
                        settle(host)
                        assertFits(scroll, context: "monitor resized scale=\(scale) style=\(style.rawValue)")
                    }
                    XCTAssertFalse(window.isVisible)
                }
            }
        }
    }

    func testResizeAndScrollerStyleChangesKeepPatchbayFitted() throws {
        let state = makeState()
        let (window, host, scroll) = try makeWindow(state: state, width: 1100, style: .legacy)
        defer { window.close() }
        for (width, style): (Double, NSScroller.Style) in [(640, .legacy), (1400, .overlay), (1100, .legacy)] {
            window.setContentSize(CGSize(width: width, height: 720))
            scroll.scrollerStyle = style
            scroll.tile()
            settle(host)
            assertFits(scroll, context: "resize width=\(width) style=\(style.rawValue)")
        }
        XCTAssertFalse(window.isVisible)
    }

    func testViewportReaderIgnoresScrollOffsetAndDisconnects() {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 800, height: 800))
        let probe = ScrollViewportReader.Probe()
        var reports: [CGSize] = []
        probe.update = { reports.append($0) }
        document.addSubview(probe)
        scroll.documentView = document
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.close() }
        settle(scroll)
        XCTAssertEqual(reports.last, scroll.contentView.bounds.size)
        let count = reports.count
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 40))
        settle(scroll)
        XCTAssertEqual(reports.count, count)
        probe.disconnect()
        window.setContentSize(CGSize(width: 500, height: 350))
        settle(scroll)
        XCTAssertEqual(reports.count, count)
        XCTAssertFalse(window.isVisible)
    }

    func testWideDesktopAndLargeTextRemainHorizontallyReachable() throws {
        for style in [NSScroller.Style.legacy, .overlay] {
            for desktop in [false, true] {
                let state = makeState(room: desktop ? .desktop : .studio, scale: desktop ? 1 : 2)
                if desktop { state.positionPort("out-0", at: CGPoint(x: 1500, y: 24)) }
                let (window, host, scroll) = try makeWindow(state: state, width: 880, style: style)
                defer { window.close() }
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertGreaterThan(document.frame.width, scroll.contentView.bounds.width)
                scroll.contentView.scroll(to: CGPoint(x: document.frame.width - scroll.contentView.bounds.width, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                settle(host)
                let output = try XCTUnwrap(state.popupAnchors["connector-out-0-main"])
                XCTAssertGreaterThanOrEqual(output.minX, 0)
                XCTAssertLessThanOrEqual(output.maxX, host.bounds.maxX)
                XCTAssertFalse(window.isVisible)
            }
        }
    }

    private func makeState(room: Room = .studio, scale: Double = 1) -> AppState {
        let ports = (0..<8).flatMap { index in
            [
                RouterPort(id: "in-\(index)", name: "Input \(index)", direction: .input),
                RouterPort(id: "out-\(index)", name: "Output \(index)", direction: .output),
            ]
        }
        let session = Session(
            setup: Setup(ports: ports, routes: [Route(source: "in-0", destination: "out-0")]),
            room: room, textScale: scale)
        let state = AppState(initial: session, startEngine: false, persist: false)
        state.showOfflineDevices = true
        return state
    }

    private func makeWindow(state: AppState, width: Double, style: NSScroller.Style) throws
        -> (NSWindow, NSHostingView<ContentView>, NSScrollView)
    {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ContentView(state: state))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: width, height: 720),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        settle(host)
        let scroll = try XCTUnwrap(scrolls(in: host).first)
        scroll.scrollerStyle = style
        scroll.tile()
        settle(host)
        return (window, host, scroll)
    }

    private func assertFits(_ scroll: NSScrollView, context: String, file: StaticString = #filePath, line: UInt = #line)
    {
        guard let document = scroll.documentView else {
            XCTFail("Missing scroll content: \(context)", file: file, line: line)
            return
        }
        XCTAssertLessThanOrEqual(
            document.frame.width, scroll.contentView.bounds.width + 0.5,
            context, file: file, line: line)
        XCTAssertTrue(scroll.horizontalScroller?.isHidden ?? true, context, file: file, line: line)
    }

    private func settle(_ host: NSView) {
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        host.layoutSubtreeIfNeeded()
    }

    private func scrolls(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrolls(in: $0) }
    }
}
