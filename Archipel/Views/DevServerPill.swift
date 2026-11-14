import AppKit
import ArchipelCore
import SwiftUI

/// Sits on a session's tab while a server it started is listening, and opens
/// it in the browser. With several servers the newest wins; the rest are in
/// the context menu.
struct DevServerPill: View {
    /// Oldest first, never empty.
    let links: [DevServerLink]

    var body: some View {
        if let link = links.last {
            Button {
                NSWorkspace.shared.open(link.openURL)
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
                    Button("Open \(link.openURL.absoluteString)", systemImage: "safari") {
                        NSWorkspace.shared.open(link.openURL)
                    }
                }
                Divider()
                Button("Copy URL", systemImage: "document.on.document") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.openURL.absoluteString, forType: .string)
                }
            }
        }
    }
}
