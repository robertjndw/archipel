import ArchipelCore
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Must match UTExportedTypeDeclarations in Info.plist. Only used for drags inside the app.
    nonisolated static let archipelTab = UTType(exportedAs: "de.jandow.archipel.tab")
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
