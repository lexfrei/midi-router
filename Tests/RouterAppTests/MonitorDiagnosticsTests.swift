import RouterCore
import XCTest

@testable import MIDIRouterApp
@testable import RouterMIDI

@MainActor
final class MonitorDiagnosticsTests: XCTestCase {
    private func snapshot(_ diagnostics: [String], records: [MonitorRecord] = []) -> EngineSnapshot {
        EngineSnapshot(
            session: Session(), online: [], records: records, totalMessages: UInt64(records.count),
            droppedMonitorRecords: 0, fault: nil, activePreset: nil, activity: [:], diagnostics: diagnostics)
    }

    func testTransferWarningsRemainVisibleWhenEventDisplayIsPaused() {
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        state.monitorPaused = true
        state.updateFromSnapshot(snapshot(["Input: competing SysEx7 transfer dropped."]))
        XCTAssertEqual(state.routingDiagnostics, ["Input: competing SysEx7 transfer dropped."])
        XCTAssertTrue(state.records.isEmpty)
        XCTAssertNil(state.runtimeFault)
    }

    func testWarningHistoryIsBoundedAndClearedWithTheMonitor() {
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        let warnings = (0..<150).map { "Warning \($0)" }
        state.updateFromSnapshot(snapshot(warnings))
        XCTAssertEqual(state.routingDiagnostics, Array(warnings.suffix(128)))
        state.clearMonitor()
        XCTAssertTrue(state.routingDiagnostics.isEmpty)
        XCTAssertTrue(state.records.isEmpty)
    }

    func testMonitorExportKeepsWarningsDistinctFromMidiPackets() {
        let state = AppState(initial: Session(), startEngine: false, persist: false)
        let record = MonitorRecord(id: 1, source: "in", destination: "out", message: .noteOn(60))
        state.updateFromSnapshot(snapshot(["Input: transfer interrupted."], records: [record]))
        let lines = state.monitorText.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("20903C64"))
        XCTAssertEqual(lines[1], "# Input: transfer interrupted.")
        XCTAssertNil(state.runtimeFault)
    }
}
