import ASCIIUI
import SwiftUI

typealias PopupItem = ASCIIUI.PopupItem
typealias PopupMenuState = ASCIIUI.PopupMenuState
typealias PopupPlacement = ASCIIUI.PopupPlacement
typealias PopupAnchors = ASCIIUI.PopupAnchors

extension View {
    func popupAnchor(_ id: String) -> some View { asciiPopupAnchor(id) }
    func popupSurface() -> some View { asciiPopupSurface() }
}
