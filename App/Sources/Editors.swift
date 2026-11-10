import RouterCore
import SwiftUI

struct InspectorView: View {
    @ObservedObject var state: AppState
    let target: AppState.Inspector

    private var title: String {
        switch target {
        case .route: "Route"
        case .port: "Device"
        case .preset: "Preset"
        case .newRoute: "New Route"
        case .newPreset: "New Preset"
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15 * state.session.textScale, weight: .semibold, design: .monospaced))
                Spacer()
                Button(action: state.closeInspector) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).frame(minWidth: 28, minHeight: 28)
                    .accessibilityLabel("Close Inspector").accessibilityIdentifier("inspector-close")
                    .help("Close Inspector")
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch target {
                    case .route(let id): RouteInspector(state: state, id: id)
                    case .port(let id): PortInspector(state: state, id: id)
                    case .preset(let id): PresetInspector(state: state, id: id)
                    case .newRoute(let destination): NewRouteInspector(state: state, destination: destination)
                    case .newPreset: NewPresetInspector(state: state)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .id(target)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector")
    }
}

private struct InspectorField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).foregroundStyle(RouterStyle.secondaryText)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct CommittedTextField: View {
    let title: String
    let value: String
    let identifier: String
    var commitValue: (String) -> Bool
    @State private var text: String
    @State private var baseline: String
    @State private var invalid = false
    @FocusState private var focused: Bool

    init(_ title: String, value: String, identifier: String = "", commit: @escaping (String) -> Bool) {
        self.title = title
        self.value = value
        self.identifier = identifier
        commitValue = commit
        _text = State(initialValue: value)
        _baseline = State(initialValue: value)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(title, text: $text)
                .labelsHidden().textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityLabel(title).accessibilityIdentifier(identifier)
                .onSubmit(commit)
            if invalid { Text("Invalid value").foregroundStyle(.primary).accessibilityLabel("Invalid \(title)") }
        }
        .onChange(of: focused) { _, editing in if !editing { commit() } }
        .onChange(of: value) { old, new in
            if !focused || text == old {
                text = new
                invalid = false
            }
            baseline = new
        }
        .onDisappear(perform: commit)
    }
    private func commit() {
        guard text != baseline else { return }
        if commitValue(text) {
            baseline = text
            invalid = false
        } else {
            invalid = true
        }
    }
}

private struct RouteFields: View {
    @ObservedObject var state: AppState
    @Binding var route: Route
    var body: some View {
        InspectorField(title: "Input") {
            PopupPicker(
                "Input", state: state,
                selection: Binding(
                    get: { route.source },
                    set: { value in
                        var next = route
                        next.source = value
                        next.sourceSlot = nil
                        route = next
                    }),
                options: options(.input).map {
                    PopupChoice(value: $0.id, title: $0.title + (state.isOnline($0.id) ? "" : " [Offline]"))
                }, identifier: "route-input")
        }
        slotPicker(
            "Input Slot", port: state.session.setup.port(route.source), selection: $route.sourceSlot,
            identifier: "route-input-slot")
        InspectorField(title: "Output") {
            PopupPicker(
                "Output", state: state,
                selection: Binding(
                    get: { route.destination },
                    set: { value in
                        var next = route
                        next.destination = value
                        next.destinationSlot = nil
                        route = next
                    }),
                options: options(.output).map {
                    PopupChoice(value: $0.id, title: $0.title + (state.isOnline($0.id) ? "" : " [Offline]"))
                }, identifier: "route-output")
        }
        slotPicker(
            "Output Slot", port: state.session.setup.port(route.destination), selection: $route.destinationSlot,
            identifier: "route-output-slot")
        InspectorField(title: "Output Channel") {
            PopupPicker(
                "Output Channel", state: state, selection: $route.channel,
                options: [PopupChoice(value: nil as Int?, title: "AUTO")]
                    + (1...16).map { PopupChoice(value: Optional($0), title: "Channel \($0)") },
                identifier: "route-channel"
            ).disabled(route.destinationSlot != nil)
        }
        if route.destinationSlot != nil {
            Text("The output slot determines the channel.").foregroundStyle(RouterStyle.secondaryText)
        }
        Toggle("Enabled", isOn: $route.enabled)
    }
    private func options(_ direction: Direction) -> [RouterPort] {
        var ports = state.visiblePorts.filter { $0.direction == direction }
        let current = direction == .input ? route.source : route.destination
        if !ports.contains(where: { $0.id == current }), let selected = state.session.setup.port(current) {
            ports.append(selected)
        }
        return ports
    }
    @ViewBuilder private func slotPicker(
        _ title: String, port: RouterPort?, selection: Binding<UUID?>, identifier: String
    ) -> some View {
        if let port, !port.slots.isEmpty {
            InspectorField(title: title) {
                PopupPicker(
                    title, state: state, selection: selection,
                    options: [PopupChoice(value: nil as UUID?, title: "CH OTHER")]
                        + port.slots.map { PopupChoice(value: Optional($0.id), title: "\($0.name) · CH \($0.channel)") },
                    identifier: identifier)
            }
        }
    }
}

struct RouteInspector: View {
    @ObservedObject var state: AppState
    let id: UUID
    private var route: Route? { state.session.setup.routes.first { $0.id == id } }
    var body: some View {
        if let route {
            let binding = Binding(get: { self.route ?? route }, set: { state.updateRoute($0) })
            RouteFields(state: state, route: binding)
            InspectorField(title: "Transpose in Semitones") {
                HStack {
                    CommittedTextField(
                        "Transpose in semitones", value: String(route.transpose), identifier: "route-transpose"
                    ) {
                        state.setRouteTranspose(id, text: $0)
                    }.frame(width: 88 * state.session.textScale)
                    Stepper("Transpose", value: binding.transpose, in: -127...127).labelsHidden().fixedSize()
                    Spacer(minLength: 0)
                }
            }
            Text("Changes apply when a value is chosen or text entry is finished. Undo restores the previous value.")
                .foregroundStyle(RouterStyle.secondaryText)
            Text("Routing changes release held notes. Out-of-range notes are dropped.")
                .foregroundStyle(RouterStyle.secondaryText)
            Button("Remove Route", role: .destructive) { state.removeRoute(id) }
        }
    }
}

private struct NewRouteInspector: View {
    @ObservedObject var state: AppState
    @State private var draft: Route
    @State private var transpose = "0"
    init(state: AppState, destination: ConnectionHandle?) {
        self.state = state
        _draft = State(
            initialValue: Route(
                source: state.inputs.first?.id ?? "",
                destination: destination?.port ?? state.outputs.first?.id ?? "",
                destinationSlot: destination?.slot))
    }
    private var transposition: Int? { Int(transpose).flatMap { (-127...127).contains($0) ? $0 : nil } }
    var body: some View {
        Button("Create Route") {
            guard let transposition else { return }
            draft.transpose = transposition
            if state.addRoute(draft) { state.inspectRoute(draft.id, origin: state.inspectorOrigin) }
        }
        .disabled(draft.source.isEmpty || draft.destination.isEmpty || transposition == nil)
        .accessibilityIdentifier("create-route")
        if state.inputs.isEmpty || state.outputs.isEmpty {
            Text("Connect a MIDI device, open a DAW, or enable Demo Mode to create a route.")
        } else {
            RouteFields(state: state, route: $draft)
            InspectorField(title: "Transpose in Semitones") {
                HStack {
                    TextField("Transpose in semitones", text: $transpose)
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .frame(width: 88 * state.session.textScale)
                    Stepper(
                        "Transpose", value: Binding(get: { transposition ?? 0 }, set: { transpose = String($0) }),
                        in: -127...127
                    )
                    .labelsHidden().fixedSize()
                    Spacer(minLength: 0)
                }
            }
            if transposition == nil { Text("Enter a whole number from -127 to 127.") }
        }
    }
}

private struct PortInspector: View {
    @ObservedObject var state: AppState
    let id: String
    var body: some View {
        if let port = state.session.setup.port(id) {
            Text(port.name).fontWeight(.semibold).textSelection(.enabled)
            Text("\(port.direction.rawValue.capitalized) · \(state.isOnline(id) ? "Online" : "Offline")")
                .foregroundStyle(RouterStyle.secondaryText)
            InspectorField(title: "Display Name") {
                CommittedTextField("Display Name", value: port.alias) { value in
                    state.editPort(id) { $0.alias = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
            Toggle(
                "Hide From Patchbay",
                isOn: Binding(get: { port.hidden }, set: { value in state.editPort(id) { $0.hidden = value } }))
            HStack {
                Text("Port Slots").fontWeight(.semibold)
                Spacer()
                Button("[ + ]") {
                    state.editPort(id) { port in
                        guard
                            let channel = (1...16).first(where: { value in !port.slots.contains { $0.channel == value }
                            })
                        else { return }
                        port.slots.append(Slot(name: "Channel \(channel)", channel: channel))
                    }
                }.disabled(port.slots.count >= 16).accessibilityLabel("Add Port Slot")
            }
            ForEach(port.slots) { slot in
                VStack(alignment: .leading, spacing: 6) {
                    CommittedTextField("Slot Name", value: slot.name) { value in
                        state.editPort(id) { port in
                            guard let index = port.slots.firstIndex(where: { $0.id == slot.id }) else { return }
                            port.slots[index].name = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                    HStack {
                        PopupPicker(
                            "Slot Channel", state: state,
                            selection: Binding(
                                get: { slot.channel },
                                set: { value in
                                    state.editPort(id) { port in
                                        guard let index = port.slots.firstIndex(where: { $0.id == slot.id }) else {
                                            return
                                        }
                                        port.slots[index].channel = value
                                    }
                                }),
                            options: (1...16).map { channel in
                                PopupChoice(
                                    value: channel, title: "CH \(channel)",
                                    enabled: !port.slots.contains { $0.id != slot.id && $0.channel == channel })
                            }, identifier: "slot-channel-\(slot.id)")
                        Button("[ x ]") { state.removeSlot(slot.id, port: id) }
                            .accessibilityLabel("Remove slot \(slot.name)").frame(minWidth: 28, minHeight: 28)
                    }
                }
                Divider()
            }
            Text("The main port becomes CH OTHER. Removing a slot also removes its routes. Undo restores both.")
                .foregroundStyle(RouterStyle.secondaryText)
            if !state.isOnline(id) {
                PopupMenu(
                    title: "Rebind Offline Device…", label: "Rebind Offline Device", identifier: "rebind-\(id)",
                    state: state,
                    items: state.session.setup.ports.filter {
                        $0.direction == port.direction && $0.id != id && state.isOnline($0.id)
                    }.map { replacement in
                        PopupItem(title: replacement.title) {
                            let origin = state.inspectorOrigin
                            state.rebind(id, to: replacement.id)
                            if state.session.setup.port(id) == nil {
                                state.inspectPort(replacement.id, origin: origin)
                            }
                        }
                    })
            }
        }
    }
}

private struct PresetInspector: View {
    @ObservedObject var state: AppState
    let id: UUID
    var body: some View {
        if let preset = state.session.presets.first(where: { $0.id == id }) {
            InspectorField(title: "Name") {
                CommittedTextField("Preset Name", value: preset.name) { value in
                    state.editPreset(id) { $0.name = value.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            }
            InspectorField(title: "Program Change") {
                PopupPicker(
                    "Program Change", state: state,
                    selection: Binding(
                        get: { preset.program },
                        set: { value in
                            state.editPreset(id) { $0.program = value }
                        }),
                    options: [PopupChoice(value: nil as Int?, title: "Not Assigned")]
                        + (0...127).map { PopupChoice(value: Optional($0), title: String($0)) },
                    identifier: "preset-program")
            }
            Text("\(preset.setup.routes.count) saved routes").foregroundStyle(RouterStyle.secondaryText)
            Button("Recall Preset") { state.recallPreset(id) }
            Button("Replace With Current Setup") {
                let setup = state.session.setup
                state.editPreset(id) { $0.setup = setup }
            }
            Button("Remove Preset", role: .destructive) { state.removePreset(id) }
        }
    }
}

private struct NewPresetInspector: View {
    @ObservedObject var state: AppState
    @State private var name = "New Setup"
    @State private var program: Int?
    var body: some View {
        Button("Create Preset") {
            state.savePreset(name: name.trimmingCharacters(in: .whitespacesAndNewlines), program: program)
        }
        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier("create-preset")
        InspectorField(title: "Name") {
            TextField("Preset Name", text: $name).labelsHidden().textFieldStyle(.roundedBorder)
        }
        InspectorField(title: "Program Change") {
            PopupPicker(
                "Program Change", state: state, selection: $program,
                options: [PopupChoice(value: nil as Int?, title: "Not Assigned")]
                    + (0...127).map { PopupChoice(value: Optional($0), title: String($0)) },
                identifier: "preset-program")
        }
        Text("Saves the current routes and device layout. Program numbers use MIDI values 0–127.")
            .foregroundStyle(RouterStyle.secondaryText)
    }
}
