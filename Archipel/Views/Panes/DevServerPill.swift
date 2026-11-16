import AppKit
import ArchipelCore
import SwiftUI

/// Sits on a session's tab while a server it started is listening, and opens
/// it like a web link from the terminal (⌥-click flips that). With several
/// servers the newest wins; the rest are in the context menu.
struct DevServerPill: View {
    @Environment(AppModel.self) private var model
    /// Oldest first, never empty.
    let links: [DevServerLink]

    var body: some View {
        if let link = links.last {
            Button {
                model.openWebLink(link.openURL, alternate: NSEvent.modifierFlags.contains(.option))
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "globe")
                        .imageScale(.small)
                    Text(verbatim: link.label)
                        .monospacedDigit()
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.14), in: .capsule)
                .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Open \(link.openURL.absoluteString)")
            .accessibilityLabel("Open \(link.openURL.absoluteString)")
            .contextMenu {
                ForEach(links.reversed(), id: \.port) { link in
                    Button("Open \(link.openURL.absoluteString)", systemImage: "globe") {
                        model.openWebLink(link.openURL)
                    }
                }
                Divider()
                Button(
                    model.settings.webLinkDestination == .archipel ? "Open in Browser" : "Open in Archipel",
                    systemImage: model.settings.webLinkDestination == .archipel ? "safari" : "macwindow"
                ) {
                    model.openWebLink(link.openURL, alternate: true)
                }
                Button("Copy URL", systemImage: "document.on.document") {
                    model.copyToPasteboard(link.openURL.absoluteString)
                }
            }
        }
    }
}

#if DEBUG
private func previewPills() -> some View {
    let vite = DevServerLink(url: URL(string: "http://localhost:5173/")!)!
    let api = DevServerLink(url: URL(string: "http://0.0.0.0:8080")!)!
    return HStack(spacing: 12) {
        DevServerPill(links: [vite])
        // Several servers: the newest is shown, the rest are in the context menu.
        DevServerPill(links: [vite, api])
    }
    .padding()
    .environment(AppModel.preview())
}

#Preview {
    VStack(spacing: 0) {
        previewPills()
        previewPills()
            .background(.background)
            .environment(\.colorScheme, .dark)
    }
}
#endif
