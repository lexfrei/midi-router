import AppKit
import CoreAudioKit
import Foundation
import RouterCore
import RouterMIDI
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    enum Page: String, CaseIterable {
        case routes = "Routes"
        case monitor = "Monitor"
        case presets = "Presets"
        case devices = "Devices"
    }
    enum Inspector: Hashable {
        case route(UUID)
        case port(String)
        case preset(UUID)
        case newRoute(ConnectionHandle?)
        case newPreset

        var anchorID: String {
            switch self {
            case .route(let id): "route-\(id)"
            case .port(let id): "port-\(id)"
            case .preset(let id): "preset-\(id)"
            case .newRoute(let handle):
                handle.map { "connector-\($0.port)-\($0.slot?.uuidString ?? "main")" } ?? "new-route"
            case .newPreset: "new-preset"
            }
        }
    }
    @Published private(set) var inspector: Inspector?
    @Published private(set) var inspectorOrigin: CGRect?
    @Published private(set) var popupMenu: PopupMenuState?
    @Published private(set) var popupFocusReturn: String?
    var popupAnchors: [String: CGRect] = [:]
    private var popupInvocationOrigin: CGRect?
    @Published private(set) var session = Session()
    @Published var page = Page.routes
    @Published var error: String?
    @Published private(set) var online: Set<String> = []
    @Published private(set) var records: [MonitorRecord] = []
    @Published private(set) var routingDiagnostics: [String] = []
    @Published private(set) var totalMessages: UInt64 = 0
    @Published private(set) var droppedRecords: UInt64 = 0
    @Published private(set) var runtimeFault: String?
    @Published private(set) var activePreset: UUID?
    @Published private(set) var activity: [String: UInt64] = [:]
    @Published private(set) var isDemo = false
    @Published private(set) var needsRecovery = false
    @Published var showOfflineDevices = false
    @Published private(set) var visiblePortIDs: Set<String> = []
    private var deviceVisibility = DeviceVisibility()
    @Published var monitorPaused = false
    @Published var monitorFilter = ""
    @Published private(set) var selectedRoute: UUID?
    @Published private(set) var undoRevision = 0
    var undoManager = UndoManager()
    private var store: SessionStore
    private let persist: Bool
    private var engine: MIDIEngine?
    private var polling: Task<Void, Never>?
    private var demoPlayback: Task<Void, Never>?
    private var savedSession: Session?
    private var bluetooth: CABTLEMIDIWindowController?

    init(
        store: SessionStore = .standard, initial: Session? = nil, startEngine: Bool = true,
        persist: Bool = true
    ) {
        self.store = store
        self.persist = persist
        do {
            session = try initial ?? store.load()
            try session.validate()
        } catch {
            self.error =
                "Cannot open the saved session. Use Save As to keep the original file. \(error.localizedDescription)"
            needsRecovery = true
        }
        refreshDeviceVisibility()
        if startEngine {
            do {
                let engine = try MIDIEngine(
                    session: session,
                    identityURL: store.url.deletingLastPathComponent().appendingPathComponent(
                        "virtual-ports.json"))
                self.engine = engine
                try engine.start()
                polling = Task { [weak self] in
                    while !Task.isCancelled {
                        self?.poll()
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                    }
                }
            } catch { self.error = "Cannot start CoreMIDI: \(error.localizedDescription)" }
        }
    }

    var visiblePorts: [RouterPort] {
        session.setup.ports.filter { showOfflineDevices || visiblePortIDs.contains($0.id) }
    }
    var inputs: [RouterPort] { visiblePorts.filter { $0.direction == .input } }
    var outputs: [RouterPort] { visiblePorts.filter { $0.direction == .output } }
    func refreshDeviceVisibility(now: ContinuousClock.Instant = .now) {
        let known = Set(session.setup.ports.map(\.id)).union(savedSession?.setup.ports.map(\.id) ?? [])
        let effectiveOnline =
            isDemo ? online.union(session.setup.ports.filter { $0.id.hasPrefix("demo:") }.map(\.id)) : online
        let visible = deviceVisibility.update(known: known, online: effectiveOnline, now: now)
        if visible != visiblePortIDs { visiblePortIDs = visible }
    }
    var canUndo: Bool {
        _ = undoRevision
        return undoManager.canUndo
    }
    var canRedo: Bool {
        _ = undoRevision
        return undoManager.canRedo
    }
    var filteredRecords: [MonitorRecord] {
        guard !monitorFilter.isEmpty else { return records }
        return records.filter { record in
            "\(portTitle(record.source)) \(record.destination.map(portTitle) ?? "Input") \(record.message.summary) \(record.message.channel.map(String.init) ?? "System")"
                .localizedCaseInsensitiveContains(monitorFilter)
        }
    }
    func portTitle(_ id: String) -> String { session.setup.port(id)?.title ?? id }
    func isOnline(_ id: String) -> Bool { isDemo ? id.hasPrefix("demo:") : online.contains(id) }

    private func poll() {
        guard let snapshot = engine?.snapshot() else { return }
        updateFromSnapshot(snapshot)
    }
    func updateFromSnapshot(_ snapshot: EngineSnapshot) {
        online = snapshot.online
        totalMessages = snapshot.totalMessages
        droppedRecords = snapshot.droppedMonitorRecords
        runtimeFault = snapshot.fault
        routingDiagnostics.append(contentsOf: snapshot.diagnostics)
        if routingDiagnostics.count > 128 { routingDiagnostics.removeFirst(routingDiagnostics.count - 128) }
        if let preset = snapshot.activePreset { activePreset = preset }
        activity = snapshot.activity
        if !monitorPaused {
            records.append(contentsOf: snapshot.records)
            if records.count > 2000 { records.removeFirst(records.count - 2000) }
        }
        var live = snapshot.session
        if isDemo { live.setup.ports.removeAll { !$0.id.hasPrefix("demo:") } }
        if live != session {
            session = live
            reconcileInspector()
            save()
        }
        refreshDeviceVisibility()
    }

    @discardableResult func edit(_ title: String, _ change: (inout Session) -> Void) -> Bool {
        var next = session
        change(&next)
        return apply(next, title: title)
    }
    @discardableResult private func apply(_ next: Session, title: String) -> Bool {
        do {
            try next.validate()
            guard next != session else { return true }
            try engine?.update(session: next)
            let old = session
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { _ = target.apply(old, title: title) }
            }
            undoManager.setActionName(title)
            session = next
            reconcileInspector()
            refreshDeviceVisibility()
            activePreset = nil
            undoRevision += 1
            if !needsRecovery { error = nil }
            save()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
    func undo() {
        undoManager.undo()
        undoRevision += 1
    }
    func redo() {
        undoManager.redo()
        undoRevision += 1
    }
    func save() {
        guard persist, !needsRecovery, !isDemo else { return }
        do { try store.save(session) } catch {
            self.error =
                "Cannot save the session: \(error.localizedDescription). Use Save As to choose another location."
        }
    }
    private func presentInspector(_ target: Inspector, origin: CGRect?) {
        dismissPopup()
        inspectorOrigin =
            origin ?? popupInvocationOrigin ?? popupAnchors[target.anchorID]
            ?? popupAnchors[target == .newPreset ? "preset-picker" : "new-route"]
        inspector = target
    }
    func inspectRoute(_ id: UUID, origin: CGRect? = nil) {
        guard session.setup.routes.contains(where: { $0.id == id }) else { return }
        selectedRoute = id
        presentInspector(.route(id), origin: origin)
    }
    func inspectPort(_ id: String, origin: CGRect? = nil) {
        guard session.setup.port(id) != nil else { return }
        selectedRoute = nil
        presentInspector(.port(id), origin: origin)
    }
    func inspectPreset(_ id: UUID, origin: CGRect? = nil) {
        guard session.presets.contains(where: { $0.id == id }) else { return }
        selectedRoute = nil
        presentInspector(.preset(id), origin: origin)
    }
    func beginNewRoute(to destination: ConnectionHandle? = nil, origin: CGRect? = nil) {
        selectedRoute = nil
        presentInspector(.newRoute(destination), origin: origin)
    }
    func beginNewPreset() {
        selectedRoute = nil
        presentInspector(.newPreset, origin: nil)
    }
    func closeInspector() {
        dismissPopup()
        inspector = nil
        inspectorOrigin = nil
    }
    func clearSelection() {
        selectedRoute = nil
        closeInspector()
    }
    func showPopup(source: String, label: String, items: [PopupItem?], origin: CGRect? = nil) {
        if popupMenu?.source == source {
            dismissPopup()
            return
        }
        popupMenu = PopupMenuState(
            source: source, label: label, anchor: origin ?? popupAnchors[source] ?? .zero, items: items)
    }
    func dismissPopup() {
        if let menu = popupMenu { popupFocusReturn = menu.source }
        popupMenu = nil
    }
    func movePopup(_ offset: Int) { popupMenu?.move(offset) }
    func searchPopup(_ text: String, now: Double = ProcessInfo.processInfo.systemUptime) {
        popupMenu?.search(text, now: now)
    }
    func highlightPopup(_ index: Int) {
        guard let menu = popupMenu, menu.items.indices.contains(index), menu.items[index]?.enabled == true else {
            return
        }
        popupMenu?.highlighted = index
    }
    func activatePopup(index: Int? = nil) {
        guard let menu = popupMenu, let index = index ?? menu.highlighted,
            menu.items.indices.contains(index), let item = menu.items[index], item.enabled
        else { return }
        dismissPopup()
        popupInvocationOrigin = menu.anchor
        item.action()
        popupInvocationOrigin = nil
    }
    func deleteSelectedRoute() {
        if let id = selectedRoute { removeRoute(id) }
    }
    private func reconcileInspector() {
        if let id = selectedRoute, !session.setup.routes.contains(where: { $0.id == id }) { selectedRoute = nil }
        switch inspector {
        case .route(let id):
            if !session.setup.routes.contains(where: { $0.id == id }) { closeInspector() }
        case .port(let id):
            if session.setup.port(id) == nil { closeInspector() }
        case .preset(let id):
            if !session.presets.contains(where: { $0.id == id }) { closeInspector() }
        default: break
        }
    }
    @discardableResult func editRoute(_ id: UUID, _ change: (inout Route) -> Void) -> Bool {
        guard var route = session.setup.routes.first(where: { $0.id == id }) else { return false }
        change(&route)
        return updateRoute(route)
    }
    @discardableResult func editPort(_ id: String, _ change: (inout RouterPort) -> Void) -> Bool {
        guard var port = session.setup.port(id) else { return false }
        change(&port)
        return updatePort(port)
    }
    @discardableResult func editPreset(_ id: UUID, _ change: (inout Preset) -> Void) -> Bool {
        guard var preset = session.presets.first(where: { $0.id == id }) else { return false }
        change(&preset)
        return updatePreset(preset)
    }
    @discardableResult func setRouteTranspose(_ id: UUID, text: String) -> Bool {
        guard session.setup.routes.contains(where: { $0.id == id }) else { return false }
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), (-127...127).contains(value) else {
            error = "Transpose must be a whole number from -127 to 127 semitones."
            return false
        }
        return editRoute(id) { $0.transpose = value }
    }
    @discardableResult func addRoute(_ route: Route) -> Bool { edit("Add Route") { $0.setup.routes.append(route) } }
    @discardableResult func updateRoute(_ route: Route) -> Bool {
        edit("Edit Route") { session in
            if let index = session.setup.routes.firstIndex(where: { $0.id == route.id }) {
                session.setup.routes[index] = route
            }
        }
    }
    func removeRoute(_ id: UUID) {
        edit("Remove Route") { $0.setup.routes.removeAll { $0.id == id } }
        if selectedRoute == id { selectedRoute = nil }
    }
    func toggleRoute(_ id: UUID) {
        edit("Toggle Route") { session in
            if let index = session.setup.routes.firstIndex(where: { $0.id == id }) {
                session.setup.routes[index].enabled.toggle()
            }
        }
    }
    @discardableResult func updatePort(_ port: RouterPort) -> Bool {
        edit("Edit Device") { session in
            if let index = session.setup.ports.firstIndex(where: { $0.id == port.id }) {
                let slots = Set(port.slots.map(\.id))
                session.setup.routes.removeAll { route in
                    (route.source == port.id && route.sourceSlot.map { !slots.contains($0) } == true)
                        || (route.destination == port.id
                            && route.destinationSlot.map { !slots.contains($0) } == true)
                }
                session.setup.ports[index] = port
            }
        }
    }
    func removeSlot(_ id: UUID, port: String) {
        edit("Remove Port Slot") { session in
            guard let index = session.setup.ports.firstIndex(where: { $0.id == port }) else { return }
            session.setup.ports[index].slots.removeAll { $0.id == id }
            session.setup.routes.removeAll {
                ($0.source == port && $0.sourceSlot == id)
                    || ($0.destination == port && $0.destinationSlot == id)
            }
        }
    }
    func movePort(_ id: String, by offset: Int) {
        edit("Reorder Device") { session in
            guard let index = session.setup.ports.firstIndex(where: { $0.id == id }) else { return }
            let candidates = session.setup.ports.indices.filter {
                session.setup.ports[$0].direction == session.setup.ports[index].direction
            }
            guard let position = candidates.firstIndex(of: index),
                candidates.indices.contains(position + offset)
            else { return }
            session.setup.ports.swapAt(index, candidates[position + offset])
        }
    }
    func positionPort(_ id: String, at point: CGPoint) {
        edit("Move Device") { session in
            guard let index = session.setup.ports.firstIndex(where: { $0.id == id }) else { return }
            session.setup.ports[index].position = Position(x: max(0, point.x), y: max(0, point.y))
        }
    }
    func changeRoom(_ room: Room) { edit("Change Room") { $0.room = room } }
    func changeTextSize(_ change: Double) {
        edit("Change Text Size") { $0.textScale = min(2, max(1, $0.textScale + change)) }
    }
    func setTrigger(_ id: String, enabled: Bool) {
        edit("Change Preset Trigger") { session in
            if enabled {
                session.programChangeSources.insert(id)
            } else {
                session.programChangeSources.remove(id)
            }
        }
    }
    @discardableResult func savePreset(name: String, program: Int?) -> UUID? {
        let preset = Preset(name: name, program: program, setup: session.setup)
        return edit("Save Preset", { $0.presets.append(preset) }) ? preset.id : nil
    }
    @discardableResult func updatePreset(_ preset: Preset) -> Bool {
        edit("Edit Preset") { session in
            if let index = session.presets.firstIndex(where: { $0.id == preset.id }) {
                session.presets[index] = preset
            }
        }
    }
    func removePreset(_ id: UUID) { edit("Remove Preset") { $0.presets.removeAll { $0.id == id } } }
    func recallPreset(_ id: UUID) {
        guard let preset = session.presets.first(where: { $0.id == id }) else { return }
        edit("Recall Preset") { $0.setup = preset.setup.retainingPorts(from: $0.setup) }
        activePreset = id
    }
    func connect(_ handle: ConnectionHandle, to port: RouterPort, slot: UUID?) -> Bool {
        guard let source = session.setup.port(handle.port), source.direction == .input,
            port.direction == .output
        else { return false }
        guard
            !session.setup.routes.contains(where: {
                $0.source == handle.port && $0.sourceSlot == handle.slot && $0.destination == port.id
                    && $0.destinationSlot == slot
            })
        else { return false }
        addRoute(
            Route(
                source: handle.port, destination: port.id, sourceSlot: handle.slot, destinationSlot: slot))
        return error == nil || needsRecovery
    }
    func rebind(_ oldID: String, to newID: String) {
        edit("Rebind Device") { session in
            guard oldID != newID, let target = session.setup.port(newID),
                let old = session.setup.port(oldID), old.direction == target.direction
            else { return }
            func replace(_ setup: inout Setup) {
                guard var port = setup.port(oldID) else { return }
                port.id = newID
                port.name = target.name
                setup.ports.removeAll { $0.id == oldID || $0.id == newID }
                setup.ports.append(port)
                for index in setup.routes.indices {
                    if setup.routes[index].source == oldID { setup.routes[index].source = newID }
                    if setup.routes[index].destination == oldID { setup.routes[index].destination = newID }
                }
            }
            replace(&session.setup)
            for index in session.presets.indices { replace(&session.presets[index].setup) }
            if session.programChangeSources.remove(oldID) != nil {
                session.programChangeSources.insert(newID)
            }
        }
    }
    func panic() { engine?.panic() }
    func resume() {
        engine?.resume()
        runtimeFault = nil
    }
    var monitorText: String {
        let events = filteredRecords.map { record in
            "\(record.message.timestamp)\t\(portTitle(record.source))\t\(record.destination.map(portTitle) ?? "Input")\t\(record.message.groupNumber.map(String.init) ?? "—")\t\(record.message.channel.map(String.init) ?? "—")\t\(record.message.summary)\t\(record.message.umpHex)"
        }
        return (events + routingDiagnostics.map { "# \($0)" }).joined(separator: "\n")
    }
    func clearMonitor() {
        records = []
        routingDiagnostics = []
    }
    func openBluetooth() {
        if bluetooth == nil { bluetooth = CABTLEMIDIWindowController() }
        bluetooth?.showWindow(nil)
    }
    func openSession() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try SessionStore(url: url).load()
            if isDemo { setDemo(false) }
            apply(loaded, title: "Open Session")
        } catch { self.error = "Cannot open session: \(error.localizedDescription)" }
    }
    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MIDI Router.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SessionStore(url: url).save(isDemo ? savedSession ?? session : session)
            if needsRecovery {
                store = SessionStore(url: url)
                needsRecovery = false
                error = nil
            }
        } catch { self.error = "Cannot save session: \(error.localizedDescription)" }
    }
    func setDemo(_ enabled: Bool) {
        guard enabled != isDemo else { return }
        engine?.panic()
        demoPlayback?.cancel()
        if enabled {
            savedSession = session
            let demo = Setup(
                ports: [
                    RouterPort(id: "demo:input", name: "Demo Keys", direction: .input),
                    RouterPort(id: "demo:output", name: "Demo Synth", direction: .output),
                    RouterPort(id: "demo:layer", name: "Demo Layer", direction: .output),
                ],
                routes: [Route(source: "demo:input", destination: "demo:output")])
            var isolated = Session(setup: demo, room: session.room, textScale: session.textScale)
            isolated.presets = [
                Preset(
                    name: "Demo Octave", program: 1,
                    setup: Setup(
                        ports: demo.ports,
                        routes: [Route(source: "demo:input", destination: "demo:output", transpose: 12)]))
            ]
            do { try engine?.update(session: isolated) } catch {
                self.error = error.localizedDescription
                savedSession = nil
                return
            }
            isDemo = true
            session = isolated
            demoPlayback = Task { [weak self] in
                let notes: [UInt8] = [60, 64, 67, 72, 67, 64]
                var index = 0
                while !Task.isCancelled {
                    self?.engine?.inject(.noteOn(notes[index]), from: "demo:input")
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { break }
                    self?.engine?.inject(.noteOff(notes[index]), from: "demo:input")
                    index = (index + 1) % notes.count
                    do { try await Task.sleep(for: .milliseconds(150)) } catch { break }
                }
            }
        } else if let saved = savedSession {
            do { try engine?.update(session: saved) } catch {
                self.error = error.localizedDescription
                return
            }
            session = saved
            isDemo = false
            savedSession = nil
            save()
        }
        reconcileInspector()
        refreshDeviceVisibility()
        undoManager.removeAllActions()
        undoRevision += 1
    }
    func stop() {
        polling?.cancel()
        demoPlayback?.cancel()
        if isDemo, let saved = savedSession {
            session = saved
            isDemo = false
        }
        save()
        engine?.stop()
        engine = nil
    }
}

struct ConnectionHandle: Hashable {
    var port: String
    var slot: UUID?
}
