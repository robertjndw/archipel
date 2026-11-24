import AppKit
import SwiftUI
import UISupport

/// Editor for one file. Text files are editable; images, PDFs and other previewable types show in
/// Quick Look; binaries and very large files get an explanation instead. Markdown can also be shown
/// rendered.
public struct FileEditor: View {
    private let url: URL
    private let store: FileDocumentStore
    private let root: URL?
    private let onOpenLink: (URL) -> Void

    /// `root` is the repository or worktree the file belongs to. A Markdown preview loads images
    /// from inside it only, or from the file's own folder when it is left out.
    /// `onOpenLink` gets the links clicked in a Markdown preview: file URLs for relative links,
    /// anything else as written. The Markdown may come from a repository nobody has read, so do
    /// not pass every scheme on to the system; see `PreviewLinkPolicy`. Leave it out to open
    /// web and mail links and to show linked files in Finder.
    public init(url: URL, store: FileDocumentStore, root: URL? = nil, onOpenLink: ((URL) -> Void)? = nil) {
        self.url = url
        self.store = store
        self.root = root
        self.onOpenLink = onOpenLink ?? { PreviewLinkPolicy.openByDefault($0) }
    }

    public var body: some View {
        // A new identity per file drops the old watcher and text view; the buffer lives on in the store.
        FileEditorContent(buffer: store.buffer(for: url), store: store, root: root, onOpenLink: onOpenLink)
            .id(url.standardizedFileURL)
    }
}

private struct FileEditorContent: View {
    let buffer: TextBuffer
    let store: FileDocumentStore
    var root: URL?
    var onOpenLink: (URL) -> Void = { PreviewLinkPolicy.openByDefault($0) }

    var body: some View {
        VStack(spacing: 0) {
            if buffer.state == .text, buffer.isMarkdown {
                MarkdownHeader(buffer: buffer)
                Divider()
            }
            if buffer.state == .text {
                if let conflict = buffer.conflict {
                    ConflictBar(conflict: conflict, buffer: buffer)
                    Divider()
                }
                if let error = buffer.saveError {
                    SaveErrorBar(
                        message: error,
                        // A failed attempt shows its own error in this bar.
                        saveAsUTF8: buffer.saveFailedOnEncoding ? { try? buffer.saveAsUTF8() } : nil
                    ) { buffer.saveError = nil }
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
            if buffer.isMarkdown, buffer.showsPreview {
                MarkdownPreview(buffer: buffer, root: root, onOpenLink: onOpenLink)
            } else {
                CodeTextView(buffer: buffer)
            }
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
        case .lineTooLong(let length):
            ContentUnavailableView {
                Label("Lines Too Long", systemImage: "text.alignleft")
            } description: {
                Text("\(buffer.name) has a line of \(length.formatted()) characters, probably minified. Files with lines over \(TextBuffer.maximumLineLength.formatted()) characters open in their default app.")
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
        // A script, an executable or an app bundle would run rather than open, and the file may
        // come from a clone nobody has read. Those are shown in Finder, and the button says so.
        Button(ExternalFileOpen.runsCodeWhenOpened(buffer.fileURL) ? "Show in Finder" : "Open in Default App") {
            ExternalFileOpen.openOrReveal(buffer.fileURL)
        }
            .buttonStyle(.glass)
    }
}

/// Sits above a Markdown file the way the diff header sits above a diff.
private struct MarkdownHeader: View {
    @Bindable var buffer: TextBuffer

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: FileSymbol.name(for: buffer.name))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(verbatim: buffer.name)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            Spacer(minLength: 8)
            Picker("Presentation", selection: $buffer.showsPreview) {
                Label("Source", systemImage: "chevron.left.forwardslash.chevron.right").tag(false)
                Label("Preview", systemImage: "eye").tag(true)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help("Show the Markdown source or the rendered preview")
            .accessibilityIdentifier("editor.markdownPresentation")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .frame(height: 32)
    }
}

private struct ConflictBar: View {
    let conflict: TextBuffer.Conflict
    let buffer: TextBuffer

    var body: some View {
        // A save the conflict refused would otherwise do nothing visible at all.
        InlineBar(systemImage: "exclamationmark.triangle.fill", tint: .orange, attention: buffer.refusedSaveCount) {
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
    var saveAsUTF8: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        InlineBar(systemImage: "xmark.octagon.fill", tint: .red) {
            Text("Couldn't save: \(message)")
                .textSelection(.enabled)
        } actions: {
            if let saveAsUTF8 {
                Button("Save as UTF-8", action: saveAsUTF8)
                    .buttonStyle(.glass)
                    .help("Save the file in UTF-8, which can hold every character")
            }
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
    /// Each change wiggles the symbol once.
    var attention = 0
    @ViewBuilder let message: Message
    @ViewBuilder let actions: Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(systemImage: String, tint: Color, attention: Int = 0, @ViewBuilder message: () -> Message, @ViewBuilder actions: () -> Actions) {
        self.systemImage = systemImage
        self.tint = tint
        self.attention = attention
        self.message = message()
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                // Keyed to a constant under Reduce Motion; the beep that comes with it still tells.
                .symbolEffect(.wiggle, value: reduceMotion ? 0 : attention)
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

#Preview("Markdown") {
    previewEditor(.previewSample(url: PreviewSamples.url("README.md"), text: PreviewSamples.markdownSource))
}

#Preview("Markdown Preview") {
    let buffer = TextBuffer.previewSample(url: PreviewSamples.url("README.md"), text: PreviewSamples.markdownSource)
    buffer.showsPreview = true
    return previewEditor(buffer)
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

#Preview("Can't Encode") {
    let buffer = TextBuffer.previewSample(
        url: PreviewSamples.url("legacy.txt"),
        text: "caf\u{e9}\n",
        edit: "\u{1F600}",
        saveError: TextFileFormat.EncodingError(encoding: .windowsCP1252).localizedDescription,
        saveFailedOnEncoding: true
    )
    return previewEditor(buffer)
}

#Preview("Too Large") {
    previewEditor(.previewSample(url: PreviewSamples.url("data/events.log"), state: .tooLarge(48_200_000)))
}

#Preview("Lines Too Long") {
    previewEditor(.previewSample(url: PreviewSamples.url("dist/bundle.min.js"), state: .lineTooLong(1_840_000)))
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
