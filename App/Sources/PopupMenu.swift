import ASCIIUI
import AppKit
import SwiftUI

@MainActor
final class PopupContextView: NSView {
    var invoke: ((CGPoint) -> Void)?
    override var isFlipped: Bool { true }

    static func accepts(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        return event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        Self.accepts(NSApp.currentEvent) ? super.hitTest(point) : nil
    }
    override func rightMouseDown(with event: NSEvent) { invoke?(convert(event.locationInWindow, from: nil)) }
    override func mouseDown(with event: NSEvent) {
        if Self.accepts(event) { invoke?(convert(event.locationInWindow, from: nil)) }
    }
}

private struct PopupContextTarget: NSViewRepresentable {
    let action: (CGPoint) -> Void
    func makeNSView(context: Context) -> PopupContextView { PopupContextView() }
    func updateNSView(_ view: PopupContextView, context: Context) { view.invoke = action }
}

extension View {
    func popupContextMenu(state: AppState, source: String, label: String, items: [PopupItem?]) -> some View {
        overlay {
            PopupContextTarget { point in
                let rect = state.popupAnchors[source] ?? .zero
                state.showPopup(
                    source: source, label: label, items: items,
                    origin: CGRect(x: rect.minX + point.x, y: rect.minY + point.y, width: 0, height: 0))
            }.accessibilityHidden(true)
        }.popupAnchor(source)
    }
}

typealias PopupChoice<Value: Hashable> = ASCIIUI.PopupChoice<Value>

struct PopupPicker<Value: Hashable>: View {
    let title: String
    @ObservedObject var state: AppState
    @Binding var selection: Value
    let options: [PopupChoice<Value>]
    let identifier: String

    init(
        _ title: String, state: AppState, selection: Binding<Value>, options: [PopupChoice<Value>],
        identifier: String = ""
    ) {
        self.title = title
        self.state = state
        _selection = selection
        self.options = options
        self.identifier = identifier
    }

    var body: some View {
        let selected = options.first { $0.value == selection }?.title ?? "Unavailable"
        if !PopupChoice.hasAlternative(to: selection, in: options) {
            Text(verbatim: selected).frame(minHeight: 28, alignment: .leading)
                .accessibilityLabel(title).accessibilityValue(selected)
                .accessibilityIdentifier(identifier)
        } else {
            PopupMenu(
                title: selected, label: title, identifier: identifier, state: state,
                items: options.map { option in
                    PopupItem(title: option.title, selected: option.value == selection, enabled: option.enabled) {
                        selection = option.value
                    }
                })
        }
    }
}

struct PopupMenu: View {
    let title: String
    let label: String
    let identifier: String
    @ObservedObject var state: AppState
    let items: [PopupItem?]
    @State private var identity = UUID()
    @FocusState private var focused: Bool
    private var source: String { identifier.isEmpty ? "menu-\(identity)" : identifier }

    var body: some View {
        Button {
            state.showPopup(source: source, label: label, items: items)
        } label: {
            Text(verbatim: "[ \(title) v ]").lineLimit(1).truncationMode(.middle)
                .frame(minHeight: 28, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .focusable()
        .focused($focused)
        .onKeyPress(keys: [.space, .return], phases: .down) { _ in
            state.showPopup(source: source, label: label, items: items)
            return .handled
        }
        .popupAnchor(source)
        .accessibilityLabel(label).accessibilityValue(title)
        .accessibilityIdentifier(identifier)
        .onChange(of: state.popupMenu?.id) { _, new in
            if new == nil && state.popupFocusReturn == source { focused = true }
        }
        .onDisappear {
            if state.popupMenu?.source == source { state.dismissPopup() }
        }
    }
}

struct PopupMenuLayer: View {
    @ObservedObject var state: AppState
    let menu: PopupMenuState
    let bounds: CGSize

    var body: some View {
        PopupMenuPanel(
            menu: menu, bounds: bounds,
            metrics: PopupMetrics(minimumTargetHeight: 28, bodyFontSize: 13, textScale: state.session.textScale),
            activate: { state.activatePopup(index: $0) }, highlight: state.highlightPopup,
            move: state.movePopup, search: { state.searchPopup($0) }, dismiss: state.dismissPopup
        )
    }
}
