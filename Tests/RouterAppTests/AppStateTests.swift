import Foundation
import RouterCore
import XCTest

@testable import MIDIRouterApp

@MainActor
final class AppStateTests: XCTestCase {
    func testRouteEditingUndoAndRedoUseOneSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let initial = Session(
            setup: Setup(ports: [
                RouterPort(id: "in", name: "Keys", direction: .input),
                RouterPort(id: "out", name: "Synth", direction: .output),
            ]))
        let state = AppState(
            store: SessionStore(url: directory.appendingPathComponent("session.json")),
            initial: initial, startEngine: false)
        state.addRoute(Route(source: "in", destination: "out", transpose: 12))
        XCTAssertEqual(state.session.setup.routes.count, 1)
        state.undo()
        XCTAssertTrue(state.session.setup.routes.isEmpty)
        state.redo()
        XCTAssertEqual(state.session.setup.routes.first?.transpose, 12)
        state.stop()
    }

    func testConnectingOneSourceToMultipleDestinationsPreservesBothRoutes() {
        let ports = [
            RouterPort(id: "in", name: "Keys", direction: .input),
            RouterPort(id: "a", name: "A", direction: .output),
            RouterPort(id: "b", name: "B", direction: .output),
        ]
        let state = AppState(initial: Session(setup: Setup(ports: ports)), startEngine: false, persist: false)
        let handle = ConnectionHandle(port: "in", slot: nil)
        XCTAssertTrue(state.connect(handle, to: ports[1], slot: nil))
        XCTAssertTrue(state.connect(handle, to: ports[2], slot: nil))
        XCTAssertEqual(Set(state.session.setup.routes.map(\.destination)), ["a", "b"])
        XCTAssertFalse(state.connect(handle, to: ports[1], slot: nil))
        XCTAssertEqual(state.session.setup.routes.count, 2)
    }

    func testInvalidEditPreservesSessionAndReportsError() {
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        state.addRoute(Route(source: "missing", destination: "missing"))
        XCTAssertTrue(state.session.setup.routes.isEmpty)
        XCTAssertNotNil(state.error)
    }

    func testDemoNeverContainsPhysicalRoutesAndRestoresOriginalSetup() {
        let initial = Session(
            setup: Setup(ports: [RouterPort(id: "physical", name: "Hardware", direction: .input)]))
        let state = AppState(initial: initial, startEngine: false, persist: false)
        state.setDemo(true)
        XCTAssertTrue(state.isDemo)
        XCTAssertTrue(
            state.session.setup.routes.allSatisfy {
                $0.source.hasPrefix("demo:") && $0.destination.hasPrefix("demo:")
            })
        state.setDemo(false)
        XCTAssertEqual(state.session.setup, initial.setup)
    }

    func testCorruptSessionIsNotOverwrittenByEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("session.json")
        let corrupt = Data("invalid".utf8)
        try corrupt.write(to: url)
        let state = AppState(store: SessionStore(url: url), startEngine: false)
        state.changeRoom(.terminal)
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        XCTAssertTrue(state.needsRecovery)
    }

    func testRemovingSlotRemovesDependentRoutesAndUndoRestoresThem() {
        let slot = Slot(name: "Bass", channel: 3)
        let setup = Setup(
            ports: [
                RouterPort(id: "in", name: "Keys", direction: .input),
                RouterPort(id: "out", name: "Synth", direction: .output, slots: [slot]),
            ],
            routes: [Route(source: "in", destination: "out", destinationSlot: slot.id)])
        let state = AppState(initial: Session(setup: setup), startEngine: false, persist: false)
        state.removeSlot(slot.id, port: "out")
        XCTAssertTrue(state.session.setup.routes.isEmpty)
        state.undo()
        XCTAssertEqual(state.session.setup, setup)
    }
}
