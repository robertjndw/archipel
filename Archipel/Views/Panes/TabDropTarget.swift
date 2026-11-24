import ArchipelCore
import SwiftUI
import UniformTypeIdentifiers

/// Files and text dropped on a tab get pasted into its session. Moving tabs is handled by the
/// reorder container in the tab bar (see `TabDragItem`).
///
/// Hovering a drag over a tab for half a second selects it, like spring-loaded folders in Finder,
/// so you can drop a file into a session that's in the background.
struct TabDropTarget: ViewModifier {
    @Environment(AppModel.self) private var model
    let tab: ArchipelCore.Tab
    @State private var isTargeted = false
    @State private var springLoad: Task<Void, Never>?

    /// Finder's default spring-loading delay.
    private static let springLoadDelay = Duration.milliseconds(500)

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
                delegate: TabDropDelegate(model: model, tab: tab, isTargeted: $isTargeted, springLoad: springLoad(_:))
            )
            .onDisappear { springLoad(false) }
    }

    private func springLoad(_ armed: Bool) {
        springLoad?.cancel()
        springLoad = nil
        guard armed else { return }
        let id = tab.id
        springLoad = Task { @MainActor in
            try? await Task.sleep(for: Self.springLoadDelay)
            guard !Task.isCancelled else { return }
            model.select(tab: id)
            Haptics.levelChange()
        }
    }
}

private struct TabDropDelegate: DropDelegate {
    static let types: [UTType] = [.fileURL, .plainText]

    let model: AppModel
    let tab: ArchipelCore.Tab
    @Binding var isTargeted: Bool
    let springLoad: (Bool) -> Void

    private var acceptsPaste: Bool { model.dropTargetSession(of: tab) != nil }

    /// Files and text both end up as a paste, so both need a terminal that is still running.
    func validateDrop(info: DropInfo) -> Bool {
        acceptsPaste && info.hasItemsConforming(to: Self.types)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = validateDrop(info: info)
        // Also for tabs that won't take the drop, so you can switch to one and drop into its
        // content instead.
        springLoad(true)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        springLoad(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        springLoad(false)
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
        guard !texts.isEmpty, acceptsPaste else { return false }
        Task {
            var strings: [String] = []
            for provider in texts {
                if let string = await provider.loadedObject(String.self) { strings.append(string) }
            }
            model.pasteText(strings.joined(separator: "\n"), intoSessionOf: tabID)
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
