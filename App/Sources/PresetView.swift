import RouterCore
import SwiftUI

struct PresetView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Presets").font(.title2)
                Spacer()
                Button("[ + Save Current Setup ]") { state.beginNewPreset() }
                    .popupAnchor("new-preset")
            }.padding(.horizontal, 16).padding(.top, 16)
            List {
                ForEach(state.session.presets) { preset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.name).fontWeight(state.activePreset == preset.id ? .semibold : .regular)
                            Text(
                                "\(preset.setup.routes.count) routes · \(preset.program.map { "PC \($0)" } ?? "No Program Change")"
                            ).foregroundStyle(RouterStyle.secondaryText)
                        }
                        Spacer()
                        Button("Recall") { state.recallPreset(preset.id) }
                        PopupMenu(
                            title: "Actions", label: "Preset Actions", identifier: "preset-\(preset.id)", state: state,
                            items: [
                                PopupItem(title: "Edit Name and Program…") { state.inspectPreset(preset.id) },
                                PopupItem(title: "Replace With Current Setup") {
                                    var next = preset
                                    next.setup = state.session.setup
                                    state.updatePreset(next)
                                },
                                PopupItem(title: "Remove Preset") { state.removePreset(preset.id) },
                            ])
                    }.padding(.vertical, 4)
                }
            }
            .overlay {
                if state.session.presets.isEmpty {
                    ContentUnavailableView(
                        "No Presets", systemImage: "square.stack",
                        description: Text(
                            "Save your routes and port slots, then recall them from this list or a MIDI Program Change."
                        ))
                }
            }
            Divider()
            DisclosureGroup("Program Change Sources") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            "Enable only the inputs that should switch presets. Program Change is matched before channel rewriting."
                        ).foregroundStyle(RouterStyle.secondaryText)
                        ForEach(state.inputs) { port in
                            Toggle(
                                port.title + (state.isOnline(port.id) ? "" : " [Offline]"),
                                isOn: Binding(
                                    get: { state.session.programChangeSources.contains(port.id) },
                                    set: { state.setTrigger(port.id, enabled: $0) }))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 180)
            }.padding(16)
        }
    }
}

struct DevicesView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Devices").font(.title2)
                Spacer()
                Toggle("Show Offline Devices", isOn: $state.showOfflineDevices).toggleStyle(.button)
                    .help("Keep offline devices visible beyond the 30-second grace period")
                Button("Bluetooth MIDI…", action: state.openBluetooth)
                Toggle("Demo Mode", isOn: Binding(get: { state.isDemo }, set: state.setDemo)).toggleStyle(
                    .button)
            }.padding(16)
            List {
                ForEach(Direction.allCases, id: \.self) { direction in
                    Section(direction == .input ? "Inputs" : "Outputs") {
                        let ports = state.visiblePorts.filter { $0.direction == direction }
                        ForEach(Array(ports.enumerated()), id: \.element.id) { index, port in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(port.title)
                                    Text(
                                        "\(state.isOnline(port.id) ? "Online" : "Offline")\(port.hidden ? " · Hidden" : "") · \(port.slots.count) slots"
                                    ).foregroundStyle(RouterStyle.secondaryText)
                                }
                                Spacer()
                                Button("[ Up ]") { state.movePort(port.id, by: -1) }.disabled(index == 0)
                                    .accessibilityLabel("Move \(port.title) up")
                                Button("[ Down ]") { state.movePort(port.id, by: 1) }.disabled(
                                    index == ports.count - 1
                                ).accessibilityLabel("Move \(port.title) down")
                                Button("Edit…") { state.inspectPort(port.id) }
                                    .popupAnchor("port-\(port.id)")
                            }.frame(minHeight: 36)
                        }
                    }
                }
            }
            Text(
                "Offline devices disappear after 30 seconds without losing their routes. Show Offline Devices to inspect or rebind them."
            )
            .font(.callout).foregroundStyle(RouterStyle.secondaryText).padding(16)
        }
    }
}
