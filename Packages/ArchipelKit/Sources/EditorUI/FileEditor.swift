import AppKit
import SwiftUI

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
        .task {
            // Lives as long as the editor is on screen; the poll covers a file that comes back after
            // being deleted, which no watch can see.
            buffer.beginWatching()
            while !Task.isCancelled {
                await buffer.reload()
                try? await Task.sleep(for: .seconds(2))
            }
            buffer.endWatching()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await buffer.reload() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch buffer.state {
        case .loading:
            Color.clear
        case .text:
            CodeTextView(buffer: buffer)
        case .preview:
            QuickLookPreview(url: buffer.url, revision: buffer.revision)
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
        Button("Open in Default App") { NSWorkspace.shared.open(buffer.url) }
    }
}

private struct ConflictBar: View {
    let conflict: TextBuffer.Conflict
    let buffer: TextBuffer

    var body: some View {
        InlineBar(systemImage: "exclamationmark.triangle.fill", tint: .yellow) {
            Text(conflict == .deleted ? "This file was deleted on disk." : "This file changed on disk.")
        } actions: {
            Button(conflict == .deleted ? "Close File" : "Reload") { buffer.discardChanges() }
                .help(conflict == .deleted ? "Discard your edits" : "Discard your edits and load the version on disk")
            Button("Keep My Changes") { buffer.keepChanges() }
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
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(tint.opacity(0.1))
    }
}
