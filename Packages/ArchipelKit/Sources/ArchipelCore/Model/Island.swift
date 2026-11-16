import Foundation

public struct Island: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    public var tint: Tint
    public var projects: [Project]

    public init(
        id: UUID = UUID(),
        name: String,
        symbol: String = "square.stack.3d.up",
        tint: Tint = .blue,
        projects: [Project] = []
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.projects = projects
    }
}
