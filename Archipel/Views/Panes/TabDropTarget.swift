import ArchipelCore
import SwiftUI
import UniformTypeIdentifiers

/// Everything that can be dropped on a tab: another tab being moved, which
/// arrives as its id string, and files or text from elsewhere, which go into
/// the tab's session as a paste.
struct TabDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let tab: ArchipelCore.Tab
    /// Any drag hovering over the tab, including a tab being reordered, which never lights it up.
    let targetChanged: (Bool) -> Void
    /// Moves the dropped tab next to this one.
    let moveTab: (ArchipelCore.Tab.ID) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if isTargeted {
                    Capsule()
                        .fill(.tint.opacity(0.12))
                        .strokeBorder(.tint, lineWidth: 1.5)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(Motion.hover, value: isTargeted)
            .onDrop(
                of: TabDropDelegate.types,
                delegate: TabDropDelegate(model: model, tab: tab, targetChanged: targetChanged, moveTab: moveTab, isTargeted: $isTargeted)
            )
    }
}

private struct TabDropDelegate: DropDelegate {
    static let types: [UTType] = [.fileURL, .plainText]

    let model: AppModel
    let tab: ArchipelCore.Tab
    let targetChanged: (Bool) -> Void
    let moveTab: (ArchipelCore.Tab.ID) -> Void
    @Binding var isTargeted: Bool

    private var acceptsPaste: Bool { model.dropTargetSession(of: tab) != nil }

    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [.fileURL]) { return acceptsPaste }
        return info.hasItemsConforming(to: [.plainText])
    }

    // Only files light the tab up. Text cannot be told apart from a tab being
    // reordered until it is dropped, and reordering never had a highlight.
    func dropEntered(info: DropInfo) {
        targetChanged(true)
        if acceptsPaste, info.hasItemsConforming(to: [.fileURL]) { isTargeted = true }
    }

    func dropExited(info: DropInfo) {
        targetChanged(false)
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        targetChanged(false)
        isTargeted = false
        let tabID = tab.id
        let files = info.itemProviders(for: [.fileURL])
        if !files.isEmpty {
            guard acceptsPaste else { return false }
            Task {
                var urls: [URL] = []
                for provider in files {
                    if let url = await provider.loadedObject(URL.self), url.isFileURL { urls.append(url) }
                }
                model.pasteFiles(urls, intoSessionOf: tabID)
            }
            return true
        }
        let texts = info.itemProviders(for: [.plainText])
        guard !texts.isEmpty else { return false }
        Task {
            var strings: [String] = []
            for provider in texts {
                if let string = await provider.loadedObject(String.self) { strings.append(string) }
            }
            if strings.count == 1, let id = UUID(uuidString: strings[0]), model.workspace.tab(id: id) != nil {
                moveTab(id)
            } else {
                model.pasteText(strings.joined(separator: "\n"), intoSessionOf: tabID)
            }
        }
        return true
    }
}

private extension NSItemProvider {
    func loadedObject<T: _ObjectiveCBridgeable & Sendable>(_ type: T.Type) async -> T? where T._ObjectiveCType: NSItemProviderReading {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: type) { object, _ in continuation.resume(returning: object) }
        }
    }
}
