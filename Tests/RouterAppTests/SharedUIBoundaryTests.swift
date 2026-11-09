import ASCIIUI
import XCTest

@testable import MIDIRouterApp

final class SharedUIBoundaryTests: XCTestCase {
    func testRouterUsesSharedMenuModel() {
        let shared: ASCIIUI.PopupItem = PopupItem(title: "Input [A]") {}
        let menu: ASCIIUI.PopupMenuState = PopupMenuState(
            source: "input", label: "Input", anchor: .zero, items: [shared])
        XCTAssertEqual(menu.items.first??.title, "Input [A]")
    }
}
