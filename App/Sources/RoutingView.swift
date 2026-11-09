import Darwin
import RouterCore
import SwiftUI

struct PatchLayout {
    var frames: [String: CGRect] = [:]
    var size: CGSize
    let scale: Double
    var nodeWidth: Double { 224 * scale }
    var rowHeight: Double { 30 * scale }
    var headerHeight: Double { 40 * scale }
    init(ports: [RouterPort], room: Room, width: Double, scale: Double) {
        self.scale = scale
        let width = max(width, 640 * scale)
        size = CGSize(width: width, height: 400)
        var nextY: [Direction: Double] = [.input: 24, .output: 24]
        for port in ports where !port.hidden {
            let height = (40 + 30 * Double(port.slots.count + 1) + 10) * scale
            var origin = CGPoint(
                x: port.direction == .input ? 24 : width - nodeWidth - 24, y: nextY[port.direction]!)
            if room == .desktop && (port.position.x > 0 || port.position.y > 0) {
                origin = CGPoint(x: port.position.x, y: port.position.y)
            }
            let rect = CGRect(origin: origin, size: CGSize(width: nodeWidth, height: height))
            frames[port.id] = rect
            nextY[port.direction] = rect.maxY + 24
            size.height = max(size.height, rect.maxY + 24)
            size.width = max(size.width, rect.maxX + 24)
        }
    }
    func dropTarget(at point: CGPoint, ports: [RouterPort]) -> ConnectionHandle? {
        for port in ports where port.direction == .output && !port.hidden {
            guard let rect = frames[port.id] else { continue }
            let slots: [UUID?] = [nil] + port.slots.map { Optional($0.id) }
            for slot in slots {
                guard let center = anchor(port: port, slot: slot) else { continue }
                let target = CGRect(
                    x: rect.minX - 14, y: center.y - rowHeight / 2, width: rect.width + 14, height: rowHeight)
                if target.contains(point) { return ConnectionHandle(port: port.id, slot: slot) }
            }
        }
        return nil
    }

    func anchor(port: RouterPort, slot: UUID?, offset: CGSize = .zero) -> CGPoint? {
        guard let rect = frames[port.id] else { return nil }
        let row = slot.flatMap { id in port.slots.firstIndex { $0.id == id }.map { $0 + 1 } } ?? 0
        return CGPoint(
            x: (port.direction == .input ? rect.maxX : rect.minX) + offset.width,
            y: rect.minY + headerHeight + rowHeight * (Double(row) + 0.5) + offset.height)
    }
}

struct RoutingView: View {
    @ObservedObject var state: AppState
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                if state.session.setup.routes.isEmpty {
                    HStack(spacing: 12) {
                        Text("Connect an input to an output. No device routes are created automatically.")
                        Spacer()
                        Button("Bluetooth MIDI…", action: state.openBluetooth)
                        Button("Try Demo") { state.setDemo(true) }.disabled(state.isDemo)
                    }.padding(16)
                }
                if state.session.room == .terminal {
                    RouteTable(state: state)
                } else {
                    Patchbay(state: state)
                    if state.session.setup.ports.contains(where: \.hidden) {
                        HStack {
                            Text("Hidden devices keep routing.").foregroundStyle(RouterStyle.secondaryText)
                            Button("Show Devices") { state.page = .devices }
                            Spacer()
                        }.padding(.horizontal, 16).padding(.vertical, 8)
                    }
                }
            }
        }
    }
}

struct RouteTable: View {
    @ObservedObject var state: AppState
    var body: some View {
        List(
            selection: Binding(
                get: { state.selectedRoute },
                set: { id in
                    if let id { state.inspectRoute(id) } else { state.clearSelection() }
                })
        ) {
            ForEach(state.session.setup.routes) { route in
                HStack(spacing: 12) {
                    Toggle(
                        "Enabled",
                        isOn: Binding(
                            get: { route.enabled },
                            set: { enabled in
                                var updated = route
                                updated.enabled = enabled
                                state.updateRoute(updated)
                            })
                    )
                    .labelsHidden().accessibilityLabel(
                        "Enable route from \(state.portTitle(route.source)) to \(state.portTitle(route.destination))"
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(state.portTitle(route.source))  >  \(state.portTitle(route.destination))")
                        Text(routeDescription(route, setup: state.session.setup)).foregroundStyle(
                            RouterStyle.secondaryText)
                        if !state.isOnline(route.source) || !state.isOnline(route.destination) {
                            Text("[ Offline · Route Retained ]").foregroundStyle(RouterStyle.secondaryText)
                        }
                    }
                    Spacer()
                    Button("[ Edit ]") { state.inspectRoute(route.id) }.popupAnchor("route-\(route.id)")
                    Button("[ x ]") { state.removeRoute(route.id) }.accessibilityLabel("Remove route")
                }
                .frame(minHeight: 48)
                .tag(route.id)
                .popupContextMenu(
                    state: state, source: "route-context-\(route.id)", label: "Route Actions",
                    items: [
                        PopupItem(title: "Edit Route…") { state.inspectRoute(route.id) },
                        PopupItem(title: route.enabled ? "Disable Route" : "Enable Route") {
                            state.toggleRoute(route.id)
                        },
                        PopupItem(title: "Remove Route") { state.removeRoute(route.id) },
                    ])
            }
        }
        .onDeleteCommand(perform: state.deleteSelectedRoute)
        .overlay {
            if state.session.setup.routes.isEmpty {
                VStack(spacing: 16) {
                    ContentUnavailableView(
                        "No Routes", systemImage: "point.3.connected.trianglepath.dotted",
                        description: Text(
                            "Choose New Route to select inputs, outputs, channels and transposition."))
                    Button("[ + New Route ]") { state.beginNewRoute(origin: state.popupAnchors["empty-new-route"]) }
                        .popupAnchor("empty-new-route")
                }
            }
        }
    }
}

func routeDescription(_ route: Route, setup: Setup) -> String {
    let inputSlot = setup.port(route.source)?.slots.first { $0.id == route.sourceSlot }
    let outputSlot = setup.port(route.destination)?.slots.first { $0.id == route.destinationSlot }
    var parts: [String] = []
    if let inputSlot { parts.append("\(inputSlot.name): CH \(inputSlot.channel)") }
    if let outputSlot {
        parts.append("\(outputSlot.name): CH \(outputSlot.channel)")
    } else {
        parts.append(route.channel.map { "CH \($0)" } ?? "AUTO")
    }
    if route.transpose != 0 { parts.append(String(format: "%+d semitones", route.transpose)) }
    if !route.enabled { parts.append("Disabled") }
    return parts.joined(separator: " · ")
}

struct Patchbay: View {
    @ObservedObject var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var offsets: [String: CGSize] = [:]
    @FocusState private var canvasFocused: Bool
    @State private var labelSizes: [UUID: CGSize] = [:]
    @State private var interactionPorts: [RouterPort]?
    @State private var connecting: ConnectionHandle?
    @State private var wireDrag: (source: ConnectionHandle, cursor: CGPoint)?

    var body: some View {
        GeometryReader { geometry in
            let ports = interactionPorts ?? state.visiblePorts
            let layout = PatchLayout(
                ports: ports, room: state.session.room, width: geometry.size.width,
                scale: state.session.textScale)
            let labels = state.session.setup.routes.compactMap { route -> CableLabel? in
                guard let points = endpoints(route, layout: layout) else { return nil }
                return CableLabel(
                    id: route.id, anchor: CableCurve(start: points.0, end: points.1).midpoint,
                    size: labelSizes[route.id] ?? CGSize(width: 44, height: 28))
            }
            let obstacles = layout.frames.map { id, frame in
                frame.offsetBy(dx: offsets[id]?.width ?? 0, dy: offsets[id]?.height ?? 0)
            }
            let placements = CableLabelLayout.place(labels, obstacles: obstacles)
            let contentWidth = max(layout.size.width, (placements.values.map { $0.frame.maxX }.max() ?? 0) + 16)
            let contentHeight = max(
                geometry.size.height, layout.size.height,
                (placements.values.map { $0.frame.maxY }.max() ?? 0) + 16)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    TimelineView(.animation(minimumInterval: 0.05, paused: reduceMotion || !hasActivity)) {
                        timeline in
                        Canvas { context, _ in
                            for route in state.session.setup.routes {
                                guard let points = endpoints(route, layout: layout) else { continue }
                                let curve = CableCurve(start: points.0, end: points.1)
                                let path = curve.path
                                let selected = state.selectedRoute == route.id
                                context.stroke(
                                    path,
                                    with: .color(
                                        selected ? .accentColor : .primary.opacity(route.enabled ? 0.65 : 0.35)),
                                    style: StrokeStyle(
                                        lineWidth: selected ? 2.5 : 1.5, dash: route.enabled ? [] : [4, 4]))
                                if let label = placements[route.id], label.displaced {
                                    let leader = Path { path in
                                        path.move(to: label.anchor)
                                        path.addLine(to: label.center)
                                    }
                                    context.stroke(
                                        leader, with: .color(.primary.opacity(0.4)),
                                        style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                                }
                                if route.enabled && recentlyActive(route.source) {
                                    let phase =
                                        reduceMotion
                                        ? 0.5
                                        : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(
                                            dividingBy: 0.7) / 0.7
                                    let point = curve.point(at: phase)
                                    context.fill(
                                        Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)),
                                        with: .color(.accentColor))
                                }
                            }
                            if let drag = wireDrag,
                                let source = state.session.setup.port(drag.source.port),
                                let start = layout.anchor(port: source, slot: drag.source.slot)
                            {
                                let target = layout.dropTarget(at: drag.cursor, ports: state.session.setup.ports)
                                let end =
                                    target.flatMap { handle in
                                        state.session.setup.port(handle.port).flatMap {
                                            layout.anchor(port: $0, slot: handle.slot)
                                        }
                                    } ?? drag.cursor
                                context.stroke(
                                    CableCurve(start: start, end: end).path, with: .color(.accentColor),
                                    style: StrokeStyle(lineWidth: 2.5, dash: [5, 3]))
                                context.stroke(
                                    Path(ellipseIn: CGRect(x: end.x - 6, y: end.y - 6, width: 12, height: 12)),
                                    with: .color(.accentColor), lineWidth: 2)
                            }
                        }
                        .accessibilityHidden(true)
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture(coordinateSpace: .named("patchbay")).onEnded { value in
                                let hit = state.session.setup.routes.reversed().first { route in
                                    guard let points = endpoints(route, layout: layout) else { return false }
                                    return CableCurve(start: points.0, end: points.1).contains(value.location)
                                }
                                if let hit {
                                    let canvas = state.popupAnchors["patchbay-content"] ?? .zero
                                    let point = CGPoint(
                                        x: canvas.minX + value.location.x, y: canvas.minY + value.location.y)
                                    state.inspectRoute(hit.id, origin: CGRect(origin: point, size: .zero))
                                } else {
                                    state.clearSelection()
                                }
                                canvasFocused = true
                            })
                    }
                    ForEach(state.session.setup.routes) { route in
                        if let placement = placements[route.id] {
                            Button {
                                state.inspectRoute(route.id)
                                canvasFocused = true
                            } label: {
                                Text(routeDescription(route, setup: state.session.setup))
                                    .font(.system(size: 12 * state.session.textScale, design: .monospaced))
                                    .fixedSize()
                                    .padding(.horizontal, 6).frame(minHeight: 28)
                                    .background(
                                        Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.borderless)
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(key: RouteLabelSizes.self, value: [route.id: geometry.size])
                                }
                            )
                            .accessibilityLabel(
                                "Edit route from \(state.portTitle(route.source)) to \(state.portTitle(route.destination)), \(routeDescription(route, setup: state.session.setup))"
                            )
                            .accessibilityIdentifier("route-label-\(route.id)")
                            .popupAnchor("route-\(route.id)")
                            .position(placement.center)
                        }
                    }
                    ForEach(ports.filter { !$0.hidden }) { port in
                        if let rect = layout.frames[port.id] {
                            node(port, layout: layout)
                                .frame(width: rect.width, height: rect.height)
                                .offset(
                                    x: rect.minX + (offsets[port.id]?.width ?? 0),
                                    y: rect.minY + (offsets[port.id]?.height ?? 0))
                        }
                    }
                }
                .onPreferenceChange(RouteLabelSizes.self) { labelSizes = $0 }
                .coordinateSpace(name: "patchbay")
                .frame(
                    width: contentWidth, height: contentHeight,
                    alignment: .topLeading
                )
                .popupAnchor("patchbay-content")
            }
            .focusable(interactions: .edit)
            .focused($canvasFocused)
            .onDeleteCommand(perform: state.deleteSelectedRoute)
            .accessibilityLabel("MIDI Patchbay")
            .safeAreaInset(edge: .top) {
                if connecting != nil || state.session.room == .glass {
                    HStack {
                        Text(
                            connecting == nil
                                ? "Drag a port to connect, or use New Route."
                                : "Choose an output port to complete the connection.")
                        Spacer()
                        if connecting != nil { Button("Cancel") { connecting = nil } }
                        Button("Route List") { state.changeRoom(.terminal) }
                    }
                    .padding(10)
                    .background(
                        reduceTransparency ? AnyShapeStyle(.background) : AnyShapeStyle(.regularMaterial))
                }
            }
        }
    }

    private var hasActivity: Bool { state.activity.keys.contains(where: recentlyActive) }
    private func recentlyActive(_ id: String) -> Bool {
        SignalActivity.isRecent(
            state.activity[id], now: mach_absolute_time(), secondsPerTick: SignalActivity.secondsPerTick)
    }
    private func endpoints(_ route: Route, layout: PatchLayout) -> (CGPoint, CGPoint)? {
        guard let source = state.session.setup.port(route.source),
            let destination = state.session.setup.port(route.destination),
            let a = layout.anchor(
                port: source, slot: route.sourceSlot, offset: offsets[source.id] ?? .zero),
            let b = layout.anchor(
                port: destination, slot: route.destinationSlot, offset: offsets[destination.id] ?? .zero)
        else { return nil }
        return (a, b)
    }
    private func node(_ port: RouterPort, layout: PatchLayout) -> some View {
        let receiving = SignalActivity.isReceiving(
            port, online: state.isOnline(port.id), lastEvent: state.activity[port.id],
            now: mach_absolute_time(), secondsPerTick: SignalActivity.secondsPerTick)
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(port.title).fontWeight(.semibold).lineLimit(1).help(port.title)
                    Text(
                        state.isOnline(port.id)
                            ? (receiving ? "Input · Receiving" : port.direction.rawValue.capitalized) : "[ Offline ]"
                    )
                    .font(.system(size: 11 * state.session.textScale, design: .monospaced)).foregroundStyle(
                        RouterStyle.secondaryText)
                }
                Spacer(minLength: 0)
                Button("[…]") { state.inspectPort(port.id) }.buttonStyle(.borderless)
                    .accessibilityLabel("Edit \(port.title)").frame(minWidth: 28, minHeight: 28)
                    .popupAnchor("port-\(port.id)")
            }
            .padding(.horizontal, 10).frame(height: layout.headerHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { value in
                        if state.session.room == .desktop {
                            if interactionPorts == nil { interactionPorts = state.visiblePorts }
                            offsets[port.id] = value.translation
                        }
                    }
                    .onEnded { value in
                        if state.session.room == .desktop, let frame = layout.frames[port.id] {
                            state.positionPort(
                                port.id,
                                at: CGPoint(
                                    x: frame.minX + value.translation.width, y: frame.minY + value.translation.height)
                            )
                        }
                        offsets[port.id] = nil
                        interactionPorts = nil
                    })
            Divider()
            connector(
                port, slot: nil, title: port.slots.isEmpty ? "All Channels" : "CH OTHER",
                height: layout.rowHeight, layout: layout)
            ForEach(port.slots) { slot in
                connector(
                    port, slot: slot.id, title: "\(slot.name) · CH \(slot.channel)", height: layout.rowHeight,
                    layout: layout)
            }
            Spacer(minLength: 0)
        }
        .background {
            RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor))
            RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(receiving ? 0.06 : 0))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(
                receiving ? Color.accentColor : Color.secondary.opacity(0.35),
                lineWidth: receiving ? 2 : 1)
        )
        .accessibilityValue(receiving ? "Receiving MIDI on this Mac" : (state.isOnline(port.id) ? "Online" : "Offline"))
        .accessibilityElement(children: .contain)
    }
    private func connector(_ port: RouterPort, slot: UUID?, title: String, height: Double, layout: PatchLayout)
        -> some View
    {
        let handle = ConnectionHandle(port: port.id, slot: slot)
        return Button {
            if port.direction == .input {
                connecting = handle
            } else if let source = connecting, state.connect(source, to: port, slot: slot) {
                connecting = nil
            } else {
                state.beginNewRoute(to: handle)
            }
        } label: {
            HStack {
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.leading, port.direction == .output ? 18 : 10)
            .padding(.trailing, port.direction == .input ? 18 : 10)
            .frame(height: height).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: port.direction == .input ? .trailing : .leading) {
            Circle().fill(Color(nsColor: .controlBackgroundColor))
                .overlay(Circle().strokeBorder(.primary.opacity(0.7), lineWidth: 1.5))
                .frame(width: 10, height: 10)
                .allowsHitTesting(false)
        }
        .accessibilityLabel(
            "\(port.direction == .input ? "Connect from" : "Connect to") \(port.title), \(title)"
        )
        .accessibilityIdentifier("connector-\(port.id)-\(slot?.uuidString ?? "main")")
        .popupAnchor("connector-\(port.id)-\(slot?.uuidString ?? "main")")
        .highPriorityGesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("patchbay"))
                .onChanged { value in
                    if port.direction == .input {
                        if interactionPorts == nil { interactionPorts = state.visiblePorts }
                        wireDrag = (handle, value.location)
                    }
                }
                .onEnded { value in
                    defer {
                        wireDrag = nil
                        interactionPorts = nil
                        connecting = nil
                    }
                    guard port.direction == .input,
                        let target = layout.dropTarget(at: value.location, ports: state.session.setup.ports),
                        let destination = state.session.setup.port(target.port)
                    else { return }
                    _ = state.connect(handle, to: destination, slot: target.slot)
                }
        )
        .help("\(port.title) · \(title)")
    }
}
