import ArchipelCore
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Must match UTExportedTypeDeclarations in Info.plist. Only used for drags inside the app.
    nonisolated static let archipelTab = UTType(exportedAs: "de.jandow.archipel.tab")
    nonisolated static let archipelProject = UTType(exportedAs: "de.jandow.archipel.project")
    nonisolated static let archipelIsland = UTType(exportedAs: "de.jandow.archipel.island")
}

/// Drag payload for reordering projects in the sidebar. Its own type for the same reason as tabs:
/// as plain text any text drag would light up a project header, and a header dropped on a session
/// tab would count as text to paste.
nonisolated struct ProjectDragItem: Codable, Transferable {
    let id: Project.ID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .archipelProject)
    }
}

/// Drag payload for tabs. A custom type instead of the tab ID as plain text: the per-tab drop
/// target accepts text (it pastes into the terminal), so it would grab tab drags and the reorder
/// container would never show its insertion gap.
nonisolated struct TabDragItem: Codable, Identifiable, Transferable {
    let id: ArchipelCore.Tab.ID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .archipelTab)
    }
}

/// Drag payload for islands in the switcher. Reordering alone wouldn't need one, but without
/// a payload and a drop destination of its own the switcher's drags end up at the sidebar's
/// folder drop, which rejects them.
nonisolated struct IslandDragItem: Codable, Identifiable, Transferable {
    let id: Island.ID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .archipelIsland)
    }
}
