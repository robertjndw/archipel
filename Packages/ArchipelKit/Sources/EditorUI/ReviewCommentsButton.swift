import AppKit
import SwiftUI

/// What a DiffViewer needs to take comments, given by the app through its commenting initializer.
struct DiffReview {
    let store: ReviewCommentStore
    let targets: [ReviewTarget]
    let onSend: (ReviewTarget.ID) -> Void
}

/// The diff header's count of the worktree's comments, opening the list of them and the send control.
/// It counts every file, since the comments go to the agent together.
struct ReviewCommentsButton: View {
    let root: URL
    let review: DiffReview
    @State private var isPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let count = review.store.comments(in: root).count
        Group {
            if count > 0 {
                Button {
                    isPresented.toggle()
                } label: {
                    Label {
                        Text(verbatim: "\(count)")
                            .monospacedDigit()
                            .contentTransition(.numericText(value: Double(count)))
                    } icon: {
                        Image(systemName: "text.bubble")
                            .foregroundStyle(.tint)
                            // Keyed to a constant under Reduce Motion, so the bubble stays still.
                            .symbolEffect(.bounce, value: reduceMotion ? 0 : count)
                    }
                    .labelStyle(.titleAndIcon)
                    .animation(reduceMotion ? nil : .smooth, value: count)
                }
                // The only glass control in the diff header, so the comments stand out.
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Review Comments")
                .accessibilityLabel(count == 1 ? Text("1 review comment") : Text("\(count) review comments"))
                .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                    ReviewCommentsList(root: root, review: review) { isPresented = false }
                }
                .transition(.opacity)
            } else if !review.store.sentComments(in: root).isEmpty {
                restoreSent
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: count > 0)
    }

    private var restoreSent: some View {
        let sent = review.store.sentComments(in: root).count
        return Button("Restore Sent Comments", systemImage: "arrow.uturn.backward") {
            review.store.restoreSent(in: root)
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .help(sent == 1
            ? "Restore the comment last sent to an agent, in case it never arrived"
            : "Restore the \(sent) comments last sent to an agent, in case they never arrived")
    }
}

private struct ReviewCommentsList: View {
    let root: URL
    let review: DiffReview
    let dismiss: () -> Void
    @State private var confirmsRemoveAll = false

    private struct FileGroup: Identifiable {
        var path: String
        var comments: [ReviewComment]
        var id: String { path }
    }

    var body: some View {
        let comments = review.store.comments(in: root)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Self.groups(comments)) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(verbatim: group.path)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(group.path)
                            ForEach(group.comments) { comment in
                                row(comment)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .frame(width: 360)
    }

    private func row(_ comment: ReviewComment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: location(comment))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Text(verbatim: comment.body)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button("Delete Comment", systemImage: "trash") {
                review.store.remove(comment.id, in: root)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete Comment")
        }
    }

    private var removeAllTitle: String {
        let count = review.store.comments(in: root).count
        return count == 1 ? String(localized: "Remove 1 review comment?") : String(localized: "Remove all \(count) review comments?")
    }

    private func location(_ comment: ReviewComment) -> String {
        var parts = [comment.side == .old ? String(localized: "Removed line \(comment.line)") : String(localized: "Line \(comment.line)")]
        if comment.staged { parts.append(String(localized: "staged")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            Button("Remove All", role: .destructive) { confirmsRemoveAll = true }
                .confirmationDialog(removeAllTitle, isPresented: $confirmsRemoveAll) {
                    Button("Remove All", role: .destructive) {
                        review.store.removeAll(in: root)
                        dismiss()
                    }
                } message: {
                    Text("The comments haven't been sent to an agent. This can't be undone.")
                }
            Spacer(minLength: 8)
            send
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var send: some View {
        switch review.targets.count {
        case 0:
            Text("No agent session")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Send") {}
                .disabled(true)
                .help("This worktree has no agent session to send comments to.")
        case 1:
            let target = review.targets[0]
            Button {
                send(to: target)
            } label: {
                Label { Text("Send to \(target.title)") } icon: { target.icon }
            }
            .buttonStyle(.glassProminent)
        default:
            Menu("Send to") {
                ForEach(review.targets) { target in
                    Button {
                        send(to: target)
                    } label: {
                        Label { Text(target.title) } icon: { target.icon }
                    }
                }
            }
            .fixedSize()
        }
    }

    private func send(to target: ReviewTarget) {
        dismiss()
        review.onSend(target.id)
    }

    private static func groups(_ comments: [ReviewComment]) -> [FileGroup] {
        var groups: [FileGroup] = []
        for comment in comments {
            if groups.last?.path == comment.path {
                groups[groups.count - 1].comments.append(comment)
            } else {
                groups.append(FileGroup(path: comment.path, comments: [comment]))
            }
        }
        return groups
    }
}

extension ReviewTarget {
    /// Same lookup as `Image(symbol:)` in the app. The agent logos live in the app's asset catalog,
    /// which `Image(_:)` finds through the main bundle, and multicolor keeps their brand colour.
    var icon: Image {
        if NSImage(symbolName: symbolName, bundle: .main, variableValue: 0) != nil {
            Image(symbolName).symbolRenderingMode(.multicolor)
        } else {
            Image(systemName: symbolName)
        }
    }
}

#if DEBUG
#Preview("Button") {
    VStack(alignment: .leading, spacing: 16) {
        PreviewVariant("One comment") {
            ReviewCommentsButton(root: PreviewSamples.root, review: PreviewSamples.review(comments: 1))
        }
        PreviewVariant("Several comments") {
            ReviewCommentsButton(root: PreviewSamples.root, review: PreviewSamples.review(comments: 4))
        }
        PreviewVariant("Sent") {
            let review = PreviewSamples.review(comments: 3)
            let _ = review.store.markSent(in: PreviewSamples.root)
            ReviewCommentsButton(root: PreviewSamples.root, review: review)
        }
    }
    .padding()
}

#Preview("List, No Agent Session") {
    ReviewCommentsList(root: PreviewSamples.root, review: PreviewSamples.review(comments: 1, targets: 0)) {}
}

#Preview("List, One Session") {
    ReviewCommentsList(root: PreviewSamples.root, review: PreviewSamples.review(comments: 4, targets: 1)) {}
}

#Preview("List, Several Sessions") {
    ReviewCommentsList(root: PreviewSamples.root, review: PreviewSamples.review(comments: 4, targets: 2)) {}
}

#Preview("List, Dark") {
    ReviewCommentsList(root: PreviewSamples.root, review: PreviewSamples.review(comments: 4, targets: 1)) {}
        .preferredColorScheme(.dark)
}
#endif
