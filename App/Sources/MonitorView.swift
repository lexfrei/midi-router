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
                TableColumn("Source") { record in
                    let text = state.portTitle(record.source)
                    Text(text).help(text)
                }.width(min: 60, ideal: 60, max: .infinity)
                TableColumn("Destination") { record in
                    let text = record.destination.map(state.portTitle) ?? "[ Input ]"
                    Text(text).help(text)
                }.width(min: 60, ideal: 60, max: .infinity)
                TableColumn("GRP") { Text($0.message.groupNumber.map(String.init) ?? "—") }.width(40)
                TableColumn("CH") { Text($0.message.channel.map(String.init) ?? "—") }.width(40)
                TableColumn("Message") { record in
                    let text = record.message.summary
                    Text(text).help(text)
                }.width(min: 80, ideal: 80, max: .infinity)
                TableColumn("UMP") { record in
                    let text = record.message.umpHex
                    Text(text).help(text)
                }.width(min: 80, ideal: 80, max: .infinity)
                TableColumn("Host Timestamp") { record in
                    let text = String(record.message.timestamp)
                    Text(text).help(text)
                }.width(min: 80, ideal: 80, max: .infinity)
            }
            .lineLimit(1)
            .overlay {
                if state.records.isEmpty {
                    ContentUnavailableView(
                        state.monitorPaused ? "Monitor Paused" : "No MIDI Messages",
                        systemImage: state.monitorPaused ? "pause.circle" : "waveform",
                        description: Text(
                            state.monitorPaused
                                ? "Turn off Pause Display to see incoming MIDI messages. Routing continues while the display is paused."
                                : "Play a connected device, send MIDI from a DAW, or enable Demo Mode."
                        ))
                }
            }
        }
    }
}
