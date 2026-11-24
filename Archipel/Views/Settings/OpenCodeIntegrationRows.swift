import AppKit
import SwiftUI

/// Where the plugin that reports OpenCode's status lives.
struct OpenCodeIntegrationRows: View {
    private var folder: URL { OpenCodePluginInstaller.directory(in: AppModel.supportDirectory) }

    var body: some View {
        Section {
            LabeledContent("Plugin") {
                HStack {
                    Text(folder.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("Reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([folder])
                    }
                    .accessibilityIdentifier("settings.openCode.reveal")
                }
            }
        } footer: {
            Text("OpenCode keeps using your background service and your providers. Archipel adds its plugin to each OpenCode it starts, next to the plugins in your own cli.json.")
        }
    }
}
