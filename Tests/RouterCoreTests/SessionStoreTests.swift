import Foundation
import XCTest

@testable import RouterCore

final class SessionStoreTests: XCTestCase {
    func testStandardSessionLocationIsIndependentOfBundleIdentifier() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(SessionStore.standard.url, support.appendingPathComponent("MIDI Router/session.json"))
    }

    func testRoundTripAndFailedLoadPreservesBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("session.json")
        let store = SessionStore(url: url)
        var session = Session()
        session.room = .terminal
        try store.save(session)
        XCTAssertEqual(try store.load(), session)
        let broken = Data("{broken".utf8)
        try broken.write(to: url)
        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(try Data(contentsOf: url), broken)
    }

    func testUnknownVersionAndInvalidSaveDoNotOverwriteGoodState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(url: folder.appendingPathComponent("session.json"))
        try store.save(Session())
        var invalid = Session()
        invalid.version = 999
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(try store.load(), Session())
        let data = try JSONEncoder().encode(invalid)
        try data.write(to: store.url)
        XCTAssertThrowsError(try store.load())
    }
}
