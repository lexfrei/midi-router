import Foundation

public struct SessionStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static var standard: SessionStore {
        SessionStore(
            url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("MIDI Router/session.json"))
    }
    public func load() throws -> Session {
        guard FileManager.default.fileExists(atPath: url.path) else { return Session() }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else {
            throw SessionError.invalid("Session file exceeds 16 MiB.")
        }
        let session = try JSONDecoder().decode(Session.self, from: Data(contentsOf: url))
        try session.validate()
        return session
    }
    public func save(_ session: Session) throws {
        try session.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        guard data.count <= 16 * 1024 * 1024 else {
            throw SessionError.invalid("Session file exceeds 16 MiB.")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
