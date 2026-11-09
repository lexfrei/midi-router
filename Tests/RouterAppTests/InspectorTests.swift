import Foundation
import RouterCore
import XCTest

@testable import MIDIRouterApp

@MainActor
final class InspectorTests: XCTestCase {
    private func makeState() -> AppState {
        let setup = Setup(
            ports: [
                RouterPort(id: "in", name: "Keys", direction: .input),
                RouterPort(id: "out", name: "Synth", direction: .output),
            ], routes: [Route(source: "in", destination: "out")])
        return AppState(
            initial: Session(setup: setup, presets: [Preset(name: "First", setup: setup)]),
            startEngine: false, persist: false)
    }

    func testInspectionChangesOnlySelectionAndHasOneTarget() throws {
        let state = makeState()
        let session = state.session
        let route = try XCTUnwrap(session.setup.routes.first)
        state.inspectRoute(route.id)
        XCTAssertEqual(state.inspector, .route(route.id))
        XCTAssertEqual(state.selectedRoute, route.id)
        state.inspectPort("in")
        XCTAssertEqual(state.inspector, .port("in"))
        XCTAssertNil(state.selectedRoute)
        state.inspectPreset(session.presets[0].id)
        XCTAssertEqual(state.inspector, .preset(session.presets[0].id))
        state.closeInspector()
        XCTAssertNil(state.inspector)
        XCTAssertEqual(state.session, session)
        XCTAssertFalse(state.canUndo)
    }

    func testCreationEditorsDoNotSwitchPages() {
        for page in AppState.Page.allCases {
            let state = makeState()
            state.page = page
            state.beginNewRoute()
            XCTAssertEqual(state.page, page)
            state.closeInspector()
            state.page = page
            state.beginNewPreset()
            XCTAssertEqual(state.page, page)
        }
    }

    func testNewRouteAndPresetDoNotExistUntilCreated() {
        let state = makeState()
        let before = state.session
        state.beginNewRoute()
        XCTAssertEqual(state.inspector, .newRoute(nil))
        state.closeInspector()
        XCTAssertEqual(state.session, before)
        state.beginNewPreset()
        XCTAssertEqual(state.inspector, .newPreset)
        state.closeInspector()
        XCTAssertEqual(state.session, before)
    }

    func testLiveRouteFieldsPreserveOtherChangesAndUndo() throws {
        let state = makeState()
        let id = try XCTUnwrap(state.session.setup.routes.first?.id)
        state.inspectRoute(id)
        XCTAssertTrue(state.editRoute(id) { $0.channel = 9 })
        XCTAssertTrue(state.setRouteTranspose(id, text: "-12"))
        XCTAssertEqual(state.session.setup.routes[0].channel, 9)
        XCTAssertEqual(state.session.setup.routes[0].transpose, -12)
        XCTAssertEqual(state.inspector, .route(id))
        state.undo()
        XCTAssertEqual(state.session.setup.routes[0].transpose, 0)
    }

    func testIncompleteAndOutOfRangeTransposeCannotMutateRoute() throws {
        let state = makeState()
        let id = try XCTUnwrap(state.session.setup.routes.first?.id)
        let original = state.session
        for text in ["", "-", "+", "1.5", "128", "-128", "9999999999999999999999"] {
            XCTAssertFalse(state.setRouteTranspose(id, text: text))
            XCTAssertEqual(state.session, original)
        }
        XCTAssertTrue(state.setRouteTranspose(id, text: "12"))
        XCTAssertEqual(state.session.setup.routes[0].transpose, 12)
    }

    func testDeleteCommandRemovesOnlySelectedRouteAndCanBeUndone() throws {
        let state = makeState()
        let first = try XCTUnwrap(state.session.setup.routes.first)
        let second = Route(source: "in", destination: "out", channel: 2)
        state.addRoute(second)
        state.undoManager.removeAllActions()
        state.inspectRoute(first.id)
        state.deleteSelectedRoute()
        XCTAssertEqual(state.session.setup.routes, [second])
        XCTAssertNil(state.selectedRoute)
        XCTAssertNil(state.inspector)
        state.undo()
        XCTAssertEqual(state.session.setup.routes, [first, second])
        state.deleteSelectedRoute()
        XCTAssertEqual(state.session.setup.routes, [first, second])
    }

    func testRemovingSelectedObjectClosesInspectorAndStaleEditsDoNothing() throws {
        let state = makeState()
        let id = try XCTUnwrap(state.session.setup.routes.first?.id)
        state.inspectRoute(id)
        state.removeRoute(id)
        XCTAssertNil(state.inspector)
        XCTAssertNil(state.selectedRoute)
        let original = state.session
        XCTAssertFalse(state.editRoute(id) { $0.transpose = 7 })
        XCTAssertEqual(state.session, original)
        state.inspectPreset(state.session.presets[0].id)
        state.removePreset(state.session.presets[0].id)
        XCTAssertNil(state.inspector)
    }

    func testFieldEditsUseCurrentDeviceAndPresetInsteadOfStaleSnapshots() {
        let state = makeState()
        let slot = Slot(name: "Lead", channel: 3)
        XCTAssertTrue(state.editPort("in") { $0.slots.append(slot) })
        XCTAssertTrue(state.editPort("in") { $0.alias = "Keyboard" })
        XCTAssertEqual(state.session.setup.ports[0].slots, [slot])
        let id = state.session.presets[0].id
        XCTAssertTrue(state.editPreset(id) { $0.program = 7 })
        XCTAssertTrue(state.editPreset(id) { $0.name = "Renamed" })
        XCTAssertEqual(state.session.presets[0].program, 7)
    }
}
