import Foundation

/// A named set of arguments to start a session with, like a Terminal profile.
public struct LaunchPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var agentID: String
    public var name: String
    /// Kept as typed so editing it in Settings shows the user's own quoting. Split with
    /// `ArgumentSplitter` at launch.
    public var arguments: String

    public init(id: UUID = UUID(), agentID: String, name: String, arguments: String) {
        self.id = id
        self.agentID = agentID
        self.name = name
        self.arguments = arguments
    }

    /// The name for menus and tab titles. The editor lets a name be cleared, and a blank menu
    /// item would be impossible to tell apart.
    public var title: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Preset" : trimmed
    }

    /// Seeded on a fresh install. The ids are fixed because these aren't written to disk until
    /// the user edits them, and new ids on every launch would churn the palette.
    public static let defaults: [LaunchPreset] = [
        ("Fable", "5A0F1C2E-3B4D-4E5F-8A6B-7C8D9E0F1A01"),
        ("Opus", "5A0F1C2E-3B4D-4E5F-8A6B-7C8D9E0F1A02"),
        ("Sonnet", "5A0F1C2E-3B4D-4E5F-8A6B-7C8D9E0F1A03"),
        ("Haiku", "5A0F1C2E-3B4D-4E5F-8A6B-7C8D9E0F1A04"),
    ].map { name, id in
        LaunchPreset(id: UUID(uuidString: id)!, agentID: AgentDefinition.claude.id, name: name, arguments: "--model \(name.lowercased())")
    }

    /// Turns the old per-agent "Extra arguments" field into a preset called "Default", marked as
    /// that agent's default and put first in its list. Agents whose field was empty get nothing,
    /// since no default means no extra arguments, same as an empty field did.
    public static func migrating(
        extraArguments: [String: String],
        into presets: [LaunchPreset]
    ) -> (presets: [LaunchPreset], defaultIDs: [String: UUID]) {
        var presets = presets
        var defaultIDs: [String: UUID] = [:]
        for (agentID, arguments) in extraArguments.sorted(by: { $0.key < $1.key }) {
            guard !arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let preset = LaunchPreset(agentID: agentID, name: "Default", arguments: arguments)
            let index = presets.firstIndex { $0.agentID == agentID } ?? presets.endIndex
            presets.insert(preset, at: index)
            defaultIDs[agentID] = preset.id
        }
        return (presets, defaultIDs)
    }
}
