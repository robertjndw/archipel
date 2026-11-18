import Foundation

public struct WorkspaceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public enum LoadError: Error, Equatable {
        /// The file could not be decoded and was moved to `backup`, so the next save starts a new
        /// file without overwriting it.
        case quarantined(backup: URL)
        /// Written by a newer version of the app. The file is left in place, and must not be saved over.
        case newerSchema(Int)
    }

    /// A missing file gives the default workspace. See `LoadError` for the two cases the caller has
    /// to tell the user about; anything else thrown means the file is still there but unread.
    public func load() throws -> Workspace {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Workspace()
        }

        do {
            let decoder = Self.makeDecoder()
            let version = try decoder.decode(Header.self, from: data).schemaVersion
            // Decoding it anyway would drop whatever the newer version added, and the next save
            // would make that loss permanent.
            if version > Workspace.currentSchemaVersion { throw LoadError.newerSchema(version) }
            if version == 1 {
                return try decoder.decode(LegacyWorkspaceV1.self, from: data).migrated()
            }
            var workspace = try decoder.decode(Workspace.self, from: data)
            workspace.schemaVersion = Workspace.currentSchemaVersion
            return workspace
        } catch is DecodingError {
            throw LoadError.quarantined(backup: try quarantineCorruptFile())
        }
    }

    private struct Header: Decodable {
        var schemaVersion: Int
    }

    public func save(_ workspace: Workspace) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.makeEncoder().encode(workspace).write(to: fileURL, options: .atomic)
    }

    // Moved rather than deleted: the next save would otherwise overwrite the user's only copy.
    private func quarantineCorruptFile() throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let name = fileURL.deletingPathExtension().lastPathComponent
        let target = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(stamp).\(fileURL.pathExtension)")
        try FileManager.default.moveItem(at: fileURL, to: target)
        return target
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
