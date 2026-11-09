import Foundation
import RouterCore
import XCTest

@testable import MIDIRouterApp

@MainActor
final class PopupTests: XCTestCase {
    func testInspectorAppearsBesideClickAndFlipsAtWindowEdge() {
        let bounds = CGSize(width: 1100, height: 720)
        let size = CGSize(width: 320, height: 500)
        let near = PopupPlacement.frame(anchor: CGRect(x: 300, y: 120, width: 0, height: 0), size: size, bounds: bounds)
        XCTAssertEqual(near.minX, 308)
        XCTAssertEqual(near.minY, 120)
        let edge = PopupPlacement.frame(
            anchor: CGRect(x: 1050, y: 650, width: 0, height: 0), size: size, bounds: bounds)
        XCTAssertEqual(edge.maxX, 1042)
        XCTAssertTrue(CGRect(origin: .zero, size: bounds).contains(edge))
    }

    func testMenusPreferBelowControlAndStayInsideSmallWindows() {
        let anchor = CGRect(x: 500, y: 20, width: 100, height: 28)
        let frame = PopupPlacement.frame(
            anchor: anchor, size: CGSize(width: 260, height: 200), bounds: CGSize(width: 640, height: 460), below: true)
        XCTAssertEqual(frame.minY, anchor.maxY + 8)
        XCTAssertLessThanOrEqual(frame.maxX, 632)
        for width in [10.0, 100, 640] {
            let bounds = CGSize(width: width, height: 120)
            let fitted = PopupPlacement.frame(anchor: anchor, size: CGSize(width: 400, height: 900), bounds: bounds)
            XCTAssertTrue(CGRect(origin: .zero, size: bounds).contains(fitted))
        }
    }

    func testInspectorFreezesInvocationAnchorAndKeyboardUsesObjectFrame() throws {
        let route = Route(source: "in", destination: "out")
        let state = AppState(
            initial: Session(
                setup: Setup(
                    ports: [
                        RouterPort(id: "in", name: "In", direction: .input),
                        RouterPort(id: "out", name: "Out", direction: .output),
                    ], routes: [route])), startEngine: false, persist: false)
        let click = CGRect(x: 320, y: 240, width: 0, height: 0)
        state.inspectRoute(route.id, origin: click)
        XCTAssertEqual(state.inspectorOrigin, click)
        let object = CGRect(x: 600, y: 100, width: 80, height: 28)
        state.popupAnchors["route-\(route.id)"] = object
        XCTAssertEqual(state.inspectorOrigin, click)
        state.inspectRoute(route.id)
        XCTAssertEqual(state.inspectorOrigin, object)
        state.beginNewRoute(origin: click)
        XCTAssertEqual(state.inspectorOrigin, click)
    }

    func testMenuNavigationSkipsDisabledRowsAndSeparators() {
        var menu = PopupMenuState(
            source: "test", label: "Test", anchor: .zero,
            items: [
                PopupItem(title: "Disabled", enabled: false) {}, nil,
                PopupItem(title: "First") {}, PopupItem(title: "Selected", selected: true) {},
            ])
        XCTAssertEqual(menu.highlighted, 3)
        menu.move(1)
        XCTAssertEqual(menu.highlighted, 2)
        menu.move(-1)
        XCTAssertEqual(menu.highlighted, 3)
        menu.search("fi", now: 1)
        XCTAssertEqual(menu.highlighted, 2)
        menu.search("s", now: 3)
        XCTAssertEqual(menu.highlighted, 3)
    }

    func testChoosingMenuItemClosesMenuAndPreservesInvocationPosition() {
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        let anchor = CGRect(x: 300, y: 30, width: 100, height: 28)
        state.popupAnchors["presets"] = anchor
        state.showPopup(
            source: "presets", label: "Presets", items: [PopupItem(title: "New Preset") { state.beginNewPreset() }])
        state.activatePopup()
        XCTAssertNil(state.popupMenu)
        XCTAssertEqual(state.popupFocusReturn, "presets")
        XCTAssertEqual(state.inspector, .newPreset)
        XCTAssertEqual(state.inspectorOrigin, anchor)
    }

    func testRemovingInspectedObjectClosesItsDropdown() {
        let preset = Preset(name: "Saved", setup: Setup())
        let state = AppState(initial: Session(presets: [preset]), startEngine: false, persist: false)
        state.inspectPreset(preset.id, origin: CGRect(x: 200, y: 200, width: 20, height: 20))
        state.showPopup(source: "program", label: "Program", items: [PopupItem(title: "AUTO") {}])
        state.removePreset(preset.id)
        XCTAssertNil(state.inspector)
        XCTAssertNil(state.popupMenu)
        XCTAssertNil(state.inspectorOrigin)
    }

    func testDismissalAndDisabledItemsDoNotPerformActions() {
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        var invoked = false
        state.showPopup(
            source: "test", label: "Test", items: [PopupItem(title: "Disabled", enabled: false) { invoked = true }])
        state.activatePopup(index: 0)
        XCTAssertFalse(invoked)
        XCTAssertNotNil(state.popupMenu)
        state.dismissPopup()
        XCTAssertNil(state.popupMenu)
        XCTAssertFalse(invoked)
    }
}
