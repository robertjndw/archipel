import Foundation

public struct WorkspaceStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> Workspace {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return Workspace()
        }

        do {
            let decoder = Self.makeDecoder()
            if try decoder.decode(Header.self, from: data).schemaVersion == 1 {
                return try decoder.decode(LegacyWorkspaceV1.self, from: data).migrated()
            }
            var workspace = try decoder.decode(Workspace.self, from: data)
            workspace.schemaVersion = Workspace.currentSchemaVersion
            return workspace
        } catch is DecodingError {
            try quarantineCorruptFile()
            return Workspace()
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
    private func quarantineCorruptFile() throws {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let name = fileURL.deletingPathExtension().lastPathComponent
        let target = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(stamp).\(fileURL.pathExtension)")
        try FileManager.default.moveItem(at: fileURL, to: target)
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
