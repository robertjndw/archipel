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

    var body: some View {
        let count = review.store.comments(in: root).count
        if count > 0 {
            Button {
                isPresented.toggle()
            } label: {
                Label {
                    Text(verbatim: "\(count)")
                        .monospacedDigit()
                } icon: {
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.tint)
                }
                .labelStyle(.titleAndIcon)
            }
            // The one glass control in the diff header: the comments are what
            // the review is working towards, so they should stand out.
            .buttonStyle(.glass)
            .controlSize(.small)
            .help("Review Comments")
            .accessibilityLabel(count == 1 ? Text("1 review comment") : Text("\(count) review comments"))
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ReviewCommentsList(root: root, review: review) { isPresented = false }
            }
        }
    }
}

private struct ReviewCommentsList: View {
    let root: URL
    let review: DiffReview
    let dismiss: () -> Void

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
            Button {
                review.store.remove(comment.id, in: root)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete Comment")
            .accessibilityLabel("Delete Comment")
        }
    }

    private func location(_ comment: ReviewComment) -> String {
        var parts = [comment.side == .old ? String(localized: "Removed line \(comment.line)") : String(localized: "Line \(comment.line)")]
        if comment.staged { parts.append(String(localized: "staged")) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            Button("Remove All", role: .destructive) {
                review.store.removeAll(in: root)
                dismiss()
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
                Label("Send to \(target.title)", systemImage: target.symbolName)
            }
            .buttonStyle(.glassProminent)
        default:
            Menu("Send to") {
                ForEach(review.targets) { target in
                    Button {
                        send(to: target)
                    } label: {
                        Label(target.title, systemImage: target.symbolName)
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
