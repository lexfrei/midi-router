import AppKit
import RouterCore
import SwiftUI

@main
struct MIDIRouterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state: AppState

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-testing") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "midi-router-ui-\(UUID().uuidString)/session.json")
            _state = StateObject(wrappedValue: AppState(store: SessionStore(url: url), persist: false))
        } else if let index = arguments.firstIndex(of: "--session"), arguments.indices.contains(index + 1) {
            _state = StateObject(
                wrappedValue: AppState(store: SessionStore(url: URL(fileURLWithPath: arguments[index + 1])))
            )
        } else {
            _state = StateObject(wrappedValue: AppState())
        }
    }
    var body: some Scene {
        Window("MIDI Router", id: "main") {
            ContentView(state: state)
                .onAppear {
                    delegate.state = state
                    #if DEBUG
                        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                            if ProcessInfo.processInfo.arguments.contains("--light") {
                                NSApp.appearance = NSAppearance(named: .aqua)
                            }
                            if ProcessInfo.processInfo.arguments.contains("--dark") {
                                NSApp.appearance = NSAppearance(named: .darkAqua)
                            }
                        }
                    #endif
                    if ProcessInfo.processInfo.arguments.contains("--demo") { state.setDemo(true) }
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands { RouterCommands(state: state) }
        Settings { RouterSettings(state: state) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?
    func applicationWillTerminate(_ notification: Notification) { state?.stop() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct RouterCommands: Commands {
    @ObservedObject var state: AppState
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Route…") { state.beginNewRoute() }.keyboardShortcut("n")
            Button("Open Session…", action: state.openSession).keyboardShortcut("o")
            Button("Save Session", action: state.save).keyboardShortcut("s")
            Button("Save Session As…", action: state.saveAs).keyboardShortcut(
                "s", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button(state.undoManager.undoMenuItemTitle, action: state.undo).keyboardShortcut("z")
                .disabled(!state.canUndo)
            Button(state.undoManager.redoMenuItemTitle, action: state.redo).keyboardShortcut(
                "z", modifiers: [.command, .shift]
            ).disabled(!state.canRedo)
        }
        CommandGroup(after: .toolbar) {
            ForEach(Array(AppState.Page.allCases.enumerated()), id: \.element) { index, page in
                Button(page.rawValue) { state.page = page }.keyboardShortcut(
                    KeyEquivalent(Character(String(index + 1))))
            }
            Divider()
            Menu("Room") {
                ForEach(Room.allCases, id: \.self) { room in
                    Button(room.rawValue.capitalized) { state.changeRoom(room) }
                }
            }
            Button("Increase Text Size") { state.changeTextSize(0.1) }.keyboardShortcut("+")
            Button("Decrease Text Size") { state.changeTextSize(-0.1) }.keyboardShortcut("-")
        }
        CommandMenu("Routing") {
            Button("Edit Selected Route…") {
                if let id = state.selectedRoute { state.inspectRoute(id) }
            }.disabled(state.selectedRoute == nil)
            Button("Enable / Disable Selected Route") {
                if let id = state.selectedRoute { state.toggleRoute(id) }
            }.disabled(state.selectedRoute == nil)
            Button("Remove Selected Route", action: state.deleteSelectedRoute)
                .disabled(state.selectedRoute == nil)
            Divider()
            Button("All Notes Off", action: state.panic).keyboardShortcut(
                ".", modifiers: [.command, .shift])
            Button("Resume Suspended Inputs", action: state.resume)
            Button("Bluetooth MIDI…", action: state.openBluetooth)
            Toggle("Demo Mode", isOn: Binding(get: { state.isDemo }, set: state.setDemo))
        }
        CommandMenu("Presets") {
            Button("Save Current Setup…") { state.beginNewPreset() }
            ForEach(state.session.presets) { preset in
                Button(preset.name) { state.recallPreset(preset.id) }
            }
        }
        CommandMenu("Monitor") {
            Toggle("Pause Display", isOn: $state.monitorPaused)
            Button("Clear Display", action: state.clearMonitor)
        }
        CommandGroup(replacing: .help) {
            Button("MIDI Router Help") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: "MIDI Router",
                    .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                        ?? "Development",
                    .credits: NSAttributedString(
                        string:
                            "Connect an input to an output by dragging a port or choosing New Route. AUTO preserves channels. Port Slots isolate or force a channel. Presets can be recalled with Program Change. Demo Mode never sends to hardware."
                    ),
                ])
            }
        }
    }
}

struct RouterSettings: View {
    @ObservedObject var state: AppState
    var body: some View {
        Form {
            Text("Appearance follows macOS. All room layouts use the same routing engine.")
            HStack {
                Text("Content Size")
                Button("Smaller") { state.changeTextSize(-0.1) }.disabled(state.session.textScale <= 1)
                Text("\(Int(state.session.textScale * 100))%")
                Button("Larger") { state.changeTextSize(0.1) }.disabled(state.session.textScale >= 2)
            }
            Text(
                "Closing the window keeps routing active. Quit MIDI Router to stop routing and release its notes."
            )
            Text(
                "MIDI 1.0 compatibility. MIDI 2.0 devices are converted by CoreMIDI. No accounts, activation or network service required."
            ).foregroundStyle(RouterStyle.secondaryText)
        }
        .padding(24)
        .frame(width: 480)
    }
}
