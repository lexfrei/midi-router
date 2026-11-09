import AppKit
import RouterMIDI
import SwiftUI

struct MonitorView: View {
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter by device, message or channel", text: $state.monitorFilter)
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("monitor-filter")
                Toggle("Pause Display", isOn: $state.monitorPaused).toggleStyle(.button)
                Button("Clear", action: state.clearMonitor)
                Button("Copy") {
                    let text = state.monitorText
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }.disabled(state.filteredRecords.isEmpty && state.routingDiagnostics.isEmpty)
            }.padding(12)
            HStack {
                Text("\(state.totalMessages) received")
                Text("\(state.records.count) displayed")
                if state.droppedRecords > 0 { Text("\(state.droppedRecords) monitor records omitted") }
                if state.monitorPaused { Text("[ Display Paused · Routing Active ]") }
                if let warning = state.routingDiagnostics.last {
                    Text(verbatim: "[ ! ] \(warning)").help(warning)
                        .accessibilityLabel("Transfer warning: \(warning)")
                }
                Spacer()
            }.lineLimit(1).font(.callout).foregroundStyle(RouterStyle.secondaryText).padding(.horizontal, 12).padding(
                .bottom, 8)
            Table(state.filteredRecords) {
                TableColumn("Source") { Text(state.portTitle($0.source)) }.width(min: 100, ideal: 160)
                TableColumn("Destination") { Text($0.destination.map(state.portTitle) ?? "[ Input ]") }
                    .width(min: 90, ideal: 150)
                TableColumn("GRP") { Text($0.message.groupNumber.map(String.init) ?? "—") }.width(40)
                TableColumn("CH") { Text($0.message.channel.map(String.init) ?? "—") }.width(40)
                TableColumn("Message") { Text($0.message.summary) }.width(min: 160, ideal: 220)
                TableColumn("UMP") { Text($0.message.umpHex) }.width(min: 100, ideal: 220)
                TableColumn("Host Timestamp") { Text(String($0.message.timestamp)) }.width(
                    min: 130, ideal: 170)
            }
            .overlay {
                if state.records.isEmpty {
                    ContentUnavailableView(
                        "No MIDI Messages", systemImage: "waveform",
                        description: Text(
                            "Play a connected device, send MIDI from a DAW, or enable Demo Mode. Pausing this display never pauses routing."
                        ))
                }
            }
        }
    }
}
