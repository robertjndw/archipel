import AppKit
import SwiftUI
import UISupport

/// Editor for one file. Text files are editable; images, PDFs and other previewable types show in
/// Quick Look; binaries and very large files get an explanation instead.
public struct FileEditor: View {
    private let url: URL
    private let store: FileDocumentStore

    public init(url: URL, store: FileDocumentStore) {
        self.url = url
        self.store = store
    }

    public var body: some View {
        // A new identity per file drops the old watcher and text view; the buffer lives on in the store.
        FileEditorContent(buffer: store.buffer(for: url), store: store)
            .id(url.standardizedFileURL)
    }
}

private struct FileEditorContent: View {
    let buffer: TextBuffer
    let store: FileDocumentStore

    var body: some View {
        VStack(spacing: 0) {
            if buffer.state == .text {
                if let conflict = buffer.conflict {
                    ConflictBar(conflict: conflict, buffer: buffer)
                    Divider()
                }
                if let error = buffer.saveError {
                    SaveErrorBar(message: error) { buffer.saveError = nil }
                    Divider()
                }
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { buffer.beginWatching() }
        .onDisappear { buffer.endWatching() }
        // The watch sees edits; the poll covers a file that comes back after being deleted, which
        // no watch can see.
        .refreshing(every: .seconds(2)) { await buffer.reload() }
    }

    @ViewBuilder
    private var content: some View {
        switch buffer.state {
        case .loading:
            Color.clear
        case .text:
            CodeTextView(buffer: buffer)
        case .preview:
            QuickLookPreview(url: buffer.fileURL, revision: buffer.revision)
        case .missing:
            ContentUnavailableView(
                "File Deleted",
                systemImage: "trash",
                description: Text("\(buffer.name) was deleted or moved. It shows up here again if it comes back.")
            )
        case .unreadable(let message):
            ContentUnavailableView("Can't Open File", systemImage: "exclamationmark.triangle", description: Text(message))
        case .tooLarge(let size):
            ContentUnavailableView {
                Label("File Too Large", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("\(buffer.name) is \(size.formatted(.byteCount(style: .file))). Files over \(TextBuffer.maximumTextSize.formatted(.byteCount(style: .file))) open in their default app.")
            } actions: {
                openInDefaultApp
            }
        case .binary:
            ContentUnavailableView {
                Label("No Preview Available", systemImage: "doc.questionmark")
            } description: {
                Text("\(buffer.name) isn't a text file.")
            } actions: {
                openInDefaultApp
            }
        }
    }

    private var openInDefaultApp: some View {
        Button("Open in Default App") { NSWorkspace.shared.open(buffer.fileURL) }
            .buttonStyle(.glass)
    }
}

private struct ConflictBar: View {
    let conflict: TextBuffer.Conflict
    let buffer: TextBuffer

    var body: some View {
        InlineBar(systemImage: "exclamationmark.triangle.fill", tint: .orange) {
            Text(conflict == .deleted ? "This file was deleted on disk." : "This file changed on disk.")
        } actions: {
            Button(conflict == .deleted ? "Discard My Edits" : "Reload") { buffer.discardChanges() }
                .buttonStyle(.glass)
                .help(conflict == .deleted ? "Discard your edits" : "Discard your edits and load the version on disk")
            Button("Keep My Changes") { buffer.keepChanges() }
                .buttonStyle(.glass)
                .help("Your next save overwrites the file on disk")
        }
    }
}

private struct SaveErrorBar: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        InlineBar(systemImage: "xmark.octagon.fill", tint: .red) {
            Text("Couldn't save: \(message)")
                .textSelection(.enabled)
        } actions: {
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Dismiss")
        }
    }
}

private struct InlineBar<Message: View, Actions: View>: View {
    let systemImage: String
    let tint: Color
    @ViewBuilder let message: Message
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            message
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .controlSize(.small)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(tint.opacity(0.1))
    }
}

#if DEBUG
@MainActor
private func previewEditor(_ buffer: TextBuffer) -> some View {
    FileEditorContent(buffer: buffer, store: FileDocumentStore())
        .frame(width: 640, height: 400)
}

@MainActor private let sampleURL = PreviewSamples.url("Sources/ActivityBadge.swift")

#Preview("Text") {
    previewEditor(.previewSample(url: sampleURL, text: PreviewSamples.swiftSource))
}

#Preview("Changed on Disk") {
    previewEditor(.previewSample(url: sampleURL, text: PreviewSamples.swiftSource, edit: "// TODO: pause animation\n", conflict: .changed))
}

#Preview("Changed on Disk, Dark") {
    previewEditor(.previewSample(url: sampleURL, text: PreviewSamples.swiftSource, edit: "// TODO: pause animation\n", conflict: .changed))
        .preferredColorScheme(.dark)
}

#Preview("Deleted on Disk") {
    previewEditor(.previewSample(url: sampleURL, text: PreviewSamples.swiftSource, edit: "// TODO: pause animation\n", conflict: .deleted))
}

#Preview("Save Failed") {
    previewEditor(.previewSample(
        url: sampleURL,
        text: PreviewSamples.swiftSource,
        edit: "// TODO: pause animation\n",
        saveError: "You don't have permission to save the file \u{201C}ActivityBadge.swift\u{201D} in the folder \u{201C}Sources\u{201D}."
    ))
}

#Preview("Too Large") {
    previewEditor(.previewSample(url: PreviewSamples.url("data/events.log"), state: .tooLarge(48_200_000)))
}

#Preview("Binary") {
    previewEditor(.previewSample(url: PreviewSamples.url("build/archipel.o"), state: .binary))
}

#Preview("Deleted") {
    previewEditor(.previewSample(url: sampleURL, state: .missing))
}

#Preview("Unreadable") {
    previewEditor(.previewSample(url: PreviewSamples.url("Sources"), state: .unreadable("This is a folder.")))
}
#endif
