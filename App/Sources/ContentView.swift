import ASCIIUI
import RouterCore
import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState
    @Environment(\.undoManager) private var windowUndoManager
    var body: some View {
        VStack(spacing: 0) {
            if let fault = state.runtimeFault {
                notice("Routing suspended: \(fault)") { Button("Resume", action: state.resume) }
            }
            if let error = state.error {
                notice(error) {
                    if state.needsRecovery { Button("Save As…", action: state.saveAs) }
                    Button("Dismiss") { state.error = nil }
                }
            }
            if state.isDemo {
                HStack {
                    Text("[ DEMO ] Synthetic MIDI only. No hardware output.")
                    Spacer()
                    Button("[ Exit Demo ]") { state.setDemo(false) }
                }.padding(12).background(.quaternary.opacity(0.35))
            }
            controls
            navigation
            Divider()
            Group {
                switch state.page {
                case .routes: RoutingView(state: state)
                case .monitor: MonitorView(state: state)
                case .presets: PresetView(state: state)
                case .devices: DevicesView(state: state)
                }
            }
            .frame(minWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                GeometryReader { geometry in
                    if let target = state.inspector {
                        let area = geometry.frame(in: .named("workspace"))
                        let anchor = state.inspectorOrigin ?? CGRect(x: area.midX, y: area.minY, width: 0, height: 0)
                        let frame = PopupPlacement.frame(
                            anchor: anchor.offsetBy(dx: -area.minX, dy: -area.minY),
                            size: CGSize(
                                width: min(400, 320 * state.session.textScale), height: 520 * state.session.textScale),
                            bounds: geometry.size)
                        InspectorView(state: state, target: target)
                            .frame(width: frame.width, height: frame.height)
                            .popupSurface()
                            .popupAnchor("inspector-panel")
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
            }

        }
        .overlay {
            GeometryReader { geometry in
                if let menu = state.popupMenu {
                    PopupMenuLayer(state: state, menu: menu, bounds: geometry.size).id(menu.id)
                }
            }
        }
        .coordinateSpace(name: "workspace")
        .onPreferenceChange(PopupAnchors.self) { state.popupAnchors = $0 }
        .onChange(of: state.page) { _, _ in state.dismissPopup() }
        .onExitCommand {
            if state.popupMenu != nil { state.dismissPopup() } else { state.closeInspector() }
        }
        .font(.system(size: 13 * state.session.textScale, design: .monospaced))
        .fontDesign(.monospaced)
        .frame(minWidth: 640, minHeight: 460)
        .onChange(of: windowUndoManager, initial: true) { _, manager in
            if let manager { state.undoManager = manager }
        }
    }
    private var navigation: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                tabs
                Spacer(minLength: 8)
                onlineStatus
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    tabs
                    Spacer(minLength: 0)
                }
                onlineStatus
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
    private var onlineStatus: some View {
        Text("\(state.visiblePorts.filter { state.isOnline($0.id) }.count) online")
            .foregroundStyle(RouterStyle.secondaryText).fixedSize()
    }
    private var tabs: some View {
        ForEach(AppState.Page.primary, id: \.self) { page in
            ASCIITab(page.rawValue, selected: state.page == page) {
                state.page = page
            }
            .foregroundStyle(state.page == page ? Color.primary : RouterStyle.secondaryText)
            .accessibilityLabel(page.rawValue)
            .accessibilityAddTraits(state.page == page ? .isSelected : [])
            .accessibilityIdentifier("page-\(page.rawValue.lowercased())")
        }
    }
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                setupControls
                Spacer(minLength: 16)
                routingControls
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 16) {
                    setupControls
                    Spacer(minLength: 0)
                }
                HStack(spacing: 16) {
                    routingControls
                    Spacer(minLength: 0)
                }
            }
        }
        .buttonStyle(.borderless)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16).padding(.top, 8)
    }
    @ViewBuilder private var setupControls: some View {
        PopupMenu(
            title: state.session.room.displayName, label: "Room", identifier: "room-picker", state: state,
            items: Room.allCases.map { room in
                PopupItem(title: room.displayName, selected: room == state.session.room) {
                    state.changeRoom(room)
                }
            })
        let name = state.session.presets.first { $0.id == state.activePreset }?.name ?? "Presets"
        PopupMenu(
            title: name, label: "Presets", identifier: "preset-picker", state: state,
            items: [PopupItem(title: "Save Current Setup…", action: state.beginNewPreset), nil]
                + state.session.presets.map { preset in
                    PopupItem(title: preset.name, selected: preset.id == state.activePreset) {
                        state.recallPreset(preset.id)
                    }
                }
        ).frame(maxWidth: 240 * state.session.textScale)
    }
    @ViewBuilder private var routingControls: some View {
        Button {
            state.beginNewRoute()
        } label: {
            Text(verbatim: "[ + Route ]").fixedSize().frame(minHeight: 28)
        }
        .accessibilityLabel("New Route").accessibilityIdentifier("new-route")
        .popupAnchor("new-route")
        .help("Create a route without dragging")
        Button(action: state.panic) {
            Text(verbatim: "[ All Notes Off ]").fixedSize().frame(minHeight: 28)
        }
        .accessibilityLabel("All Notes Off").accessibilityIdentifier("panic")
        .help("Release notes and sustain owned by this router")
    }
    private func notice<Actions: View>(_ text: String, @ViewBuilder actions: () -> Actions)
        -> some View
    {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
            Text(text).textSelection(.enabled)
            Spacer()
            actions()
        }
        .padding(12)
        .foregroundStyle(.primary)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }
}

enum RouterStyle {
    static let secondaryOpacity = 0.72
    static var secondaryColor: NSColor { .labelColor }
    static var secondaryText: Color { Color(nsColor: secondaryColor).opacity(secondaryOpacity) }
}
