import RouterCore
import XCTest

@testable import MIDIRouterApp

final class SignalActivityTests: XCTestCase {
    func testSourceReceiptDoesNotRequireAnyRoutes() {
        let source = RouterPort(id: "input", name: "Keyboard", direction: .input)
        let session = Session(setup: Setup(ports: [source]))
        XCTAssertTrue(session.setup.routes.isEmpty)
        XCTAssertTrue(
            SignalActivity.isReceiving(
                source, online: true, lastEvent: 900,
                now: 1000, secondsPerTick: 0.001))
    }
    func testReceiptExpiresAndDoesNotTreatOfflineOrOutputAsInput() {
        let source = RouterPort(id: "input", name: "Keyboard", direction: .input)
        let output = RouterPort(id: "output", name: "Synth", direction: .output)
        XCTAssertFalse(
            SignalActivity.isReceiving(
                source, online: false, lastEvent: 1000,
                now: 1000, secondsPerTick: 0.001))
        XCTAssertFalse(
            SignalActivity.isReceiving(
                output, online: true, lastEvent: 1000,
                now: 1000, secondsPerTick: 0.001))
        XCTAssertFalse(
            SignalActivity.isReceiving(
                source, online: true, lastEvent: 1000,
                now: 1800, secondsPerTick: 0.001))
        XCTAssertFalse(SignalActivity.isRecent(nil, now: 1000, secondsPerTick: 0.001))
        XCTAssertFalse(SignalActivity.isRecent(1100, now: 1000, secondsPerTick: 0.001))
    }
}
