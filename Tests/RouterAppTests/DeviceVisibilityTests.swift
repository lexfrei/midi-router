import Foundation
import RouterCore
import XCTest

@testable import MIDIRouterApp

final class DeviceVisibilityTests: XCTestCase {
    func testSavedOfflineDevicesAreHiddenBeforeAndAfterDiscovery() {
        var visibility = DeviceVisibility()
        let start = ContinuousClock.now
        let known: Set<String> = ["connected", "offline"]
        XCTAssertTrue(visibility.update(known: known, online: [], now: start).isEmpty)
        XCTAssertEqual(visibility.update(known: known, online: ["connected"], now: start), ["connected"])
        XCTAssertEqual(
            visibility.update(known: known, online: ["connected"], now: start.advanced(by: .seconds(1))),
            ["connected"])
    }

    func testNewlyLoadedOfflineDeviceDoesNotGetGracePeriod() {
        var visibility = DeviceVisibility()
        let start = ContinuousClock.now
        _ = visibility.update(known: ["connected"], online: ["connected"], now: start)
        XCTAssertEqual(
            visibility.update(
                known: ["connected", "offline"], online: ["connected"], now: start.advanced(by: .seconds(1))),
            ["connected"])
    }

    func testRelaunchDoesNotRestartOfflineGracePeriod() {
        var visibility = DeviceVisibility()
        let start = ContinuousClock.now
        _ = visibility.update(known: ["a"], online: ["a"], now: start)
        XCTAssertEqual(visibility.update(known: ["a"], online: [], now: start.advanced(by: .seconds(1))), ["a"])
        visibility = DeviceVisibility()
        XCTAssertTrue(visibility.update(known: ["a"], online: [], now: start.advanced(by: .seconds(2))).isEmpty)
    }

    func testRemovedDeviceDoesNotKeepVisibilityHistory() {
        var visibility = DeviceVisibility()
        let start = ContinuousClock.now
        _ = visibility.update(known: ["a"], online: ["a"], now: start)
        XCTAssertTrue(visibility.update(known: [], online: [], now: start.advanced(by: .seconds(1))).isEmpty)
        XCTAssertTrue(visibility.update(known: ["a"], online: [], now: start.advanced(by: .seconds(2))).isEmpty)
    }

    func testOfflineDeviceExpiresAfterThirtySecondsWithoutRestartingDeadline() {
        var visibility = DeviceVisibility()
        let start = ContinuousClock.now
        XCTAssertEqual(visibility.update(known: ["a"], online: ["a"], now: start), ["a"])
        XCTAssertEqual(visibility.update(known: ["a"], online: [], now: start), ["a"])
        XCTAssertEqual(visibility.update(known: ["a"], online: [], now: start.advanced(by: .seconds(29))), ["a"])
        XCTAssertTrue(visibility.update(known: ["a"], online: [], now: start.advanced(by: .seconds(30))).isEmpty)
    }
    func testReconnectRestoresVisibilityAndStartsNewGracePeriod() {
        var visibility = DeviceVisibility()
        let start = ContinuousClock.now
        _ = visibility.update(known: ["a"], online: [], now: start)
        XCTAssertTrue(visibility.update(known: ["a"], online: [], now: start.advanced(by: .seconds(31))).isEmpty)
        XCTAssertEqual(visibility.update(known: ["a"], online: ["a"], now: start.advanced(by: .seconds(32))), ["a"])
        XCTAssertEqual(visibility.update(known: ["a"], online: [], now: start.advanced(by: .seconds(40))), ["a"])
        XCTAssertEqual(visibility.update(known: ["a"], online: [], now: start.advanced(by: .seconds(69))), ["a"])
        XCTAssertTrue(visibility.update(known: ["a"], online: [], now: start.advanced(by: .seconds(70))).isEmpty)
    }
    @MainActor
    func testStartupHidesSavedDevicesWithoutDeletingConfiguration() {
        let session = Session(
            setup: Setup(
                ports: [
                    RouterPort(id: "in", name: "Keys", direction: .input),
                    RouterPort(id: "out", name: "Synth", direction: .output),
                ], routes: [Route(source: "in", destination: "out")]))
        let state = AppState(initial: session, startEngine: false, persist: false)
        XCTAssertTrue(state.visiblePorts.isEmpty)
        XCTAssertTrue(state.inputs.isEmpty)
        XCTAssertTrue(state.outputs.isEmpty)
        state.refreshDeviceVisibility(now: ContinuousClock.now.advanced(by: .seconds(31)))
        XCTAssertTrue(state.visiblePorts.isEmpty)
        XCTAssertEqual(state.session, session)
        state.showOfflineDevices = true
        XCTAssertEqual(state.visiblePorts, session.setup.ports)
        XCTAssertEqual(state.session, session)
    }
}
