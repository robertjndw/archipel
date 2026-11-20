import AgentKit
import ArchipelCore
import InspectorUI
import GitKit
import SwiftUI
import UniformTypeIdentifiers

/// The Ctrl-Tab panel: a row of recent tabs centered in the window, on glass like the app switcher.
/// Attach it as an overlay on the window content.
struct TabSwitcher: View {
    @Environment(TabSwitcherModel.self) private var switcher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if switcher.showsPanel, let gesture = switcher.gesture {
                // Swallows clicks so they never reach the terminal underneath.
                Color.clear
                    .contentShape(.rect)
                    .onTapGesture { switcher.cancel() }
                // Inside the branch so the overlay measures nothing while the panel is closed.
                GeometryReader { proxy in
                    SwitcherPanel(gesture: gesture, maxWidth: proxy.size.width - 64)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Leaving is instant on purpose: once Control is up the user is already looking at the
        // tab they picked. Animating the removal at all, even with an identity transition,
        // keeps the panel up for the animation's length with its state already reset.
        .animation(switcher.showsPanel ? (reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.22)) : nil, value: switcher.showsPanel)
    }

    private var transition: AnyTransition {
        .asymmetric(
            insertion: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)),
            removal: .identity
        )
    }
}

private struct SwitcherPanel: View {
    @Environment(TabSwitcherModel.self) private var switcher
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    let gesture: TabSwitch
    let maxWidth: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            cards
            ScrollViewReader { proxy in
                ScrollView(.horizontal) { cards }
                    .scrollIndicators(.never)
                    .onAppear { proxy.scrollTo(gesture.selectedID, anchor: .center) }
                    .onChange(of: gesture.selection) {
                        withAnimation(reduceMotion ? nil : .snappy) { proxy.scrollTo(gesture.selectedID, anchor: .center) }
                    }
            }
        }
        .frame(maxWidth: maxWidth)
        .fixedSize(horizontal: true, vertical: false)
        // Over a busy terminal, clear glass lets the text behind compete with the cards. A tinted
        // backing fixes that, in light and dark mode.
        .background(.background.opacity(0.5), in: .rect(cornerRadius: SwitcherMetrics.panelRadius))
        .glassEffect(.regular, in: .rect(cornerRadius: SwitcherMetrics.panelRadius))
        .contentShape(.rect(cornerRadius: SwitcherMetrics.panelRadius))
        // A tap between cards must not reach the dismissing backdrop.
        .onTapGesture {}
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent Tabs")
    }

    private var cards: some View {
        HStack(spacing: SwitcherMetrics.cardSpacing) {
            ForEach(gesture.candidates, id: \.self) { id in
                SwitcherCard(
                    tabID: id,
                    isSelected: id == gesture.selectedID,
                    isCurrent: id == switcher.startedFrom,
                    selection: selection
                )
                .id(id)
                .onContinuousHover { phase in
                    if case .active = phase, id != gesture.selectedID { switcher.hover(id) }
                }
                .onTapGesture {
                    switcher.hover(id)
                    switcher.commit()
                }
            }
        }
        .padding(SwitcherMetrics.panelPadding)
        .animation(reduceMotion ? nil : Motion.selection, value: gesture.selection)
    }
}

/// Radii are derived from each other so the highlight stays concentric with the panel and the
/// preview stays concentric with the highlight.
private enum SwitcherMetrics {
    static let previewSize = CGSize(width: 188, height: 120)
    static let previewRadius: CGFloat = 10
    static let cardPadding: CGFloat = 7
    static let cardRadius = previewRadius + cardPadding
    static let panelPadding: CGFloat = 10
    static let panelRadius = cardRadius + panelPadding
    static let cardSpacing: CGFloat = 4
}

private struct SwitcherCard: View {
    @Environment(AppModel.self) private var model
    @Environment(TabSwitcherModel.self) private var switcher
    let tabID: ArchipelCore.Tab.ID
    let isSelected: Bool
    /// The tab the gesture started from. It gets a "Current" badge.
    let isCurrent: Bool
    let selection: Namespace.ID

    var body: some View {
        let label = label
        VStack(alignment: .leading, spacing: 7) {
            preview(label)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(symbol: label.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    Text(label.title)
                        .font(.callout.weight(isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    if let activity = label.activity, activity.status != .notStarted {
                        StatusGlyph(activity: activity)
                            .controlSize(.mini)
                    } else if label.isDirty {
                        Circle()
                            .fill(.secondary)
                            .frame(width: 6, height: 6)
                            .frame(width: 18)
                            .accessibilityLabel("Unsaved changes")
                    }
                }
                Text(label.place)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 19)
            }
            .frame(height: 34)
        }
        .frame(width: SwitcherMetrics.previewSize.width)
        .padding(SwitcherMetrics.cardPadding)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: SwitcherMetrics.cardRadius, style: .continuous)
                    .fill(.primary.opacity(0.09))
                    .matchedGeometryEffect(id: "highlight", in: selection)
            }
        }
        .contentShape(.rect(cornerRadius: SwitcherMetrics.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label.title))
        .accessibilityValue(Text(label.place))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private struct Label {
        var title: String
        var symbol: String
        var place: String
        var project: Project?
        var activity: SessionActivity?
        var isDirty = false
        /// The file a file or diff tab is about, for the placeholder's Finder icon.
        var file: URL?
        var isDiff = false
    }

    /// The same names and symbols the tab row uses, so a card is recognizable as its tab.
    private var label: Label {
        let tab = model.workspace.tab(id: tabID)
        let worktree = model.workspace.worktree(containingTab: tabID)
        let project = worktree.flatMap { model.workspace.project(containingWorktree: $0.id) }
        let where_ = [project?.name, worktree?.displayName].compactMap(\.self).joined(separator: " · ")
        switch tab?.content {
        case .session(let id)?:
            let session = model.workspace.session(id: id)
            return Label(
                title: session?.displayTitle ?? "Session",
                symbol: (session.map { model.effectiveAgent(for: $0).definition } ?? .shell).symbolName,
                place: where_,
                project: project,
                activity: model.activity(for: id)
            )
        case .file(let url)?:
            return Label(
                title: url.lastPathComponent,
                symbol: FileIcon.symbol(for: url.lastPathComponent),
                place: relativeFolder(of: url.path, in: worktree) ?? where_,
                project: project,
                isDirty: model.documents.isDirty(url),
                file: url
            )
        case .diff(let path, let staged)?:
            return Label(
                title: (path as NSString).lastPathComponent,
                symbol: "plus.forwardslash.minus",
                place: "\(staged ? "Staged" : "Working Tree") · \(where_)",
                project: project,
                file: worktree?.path.appending(path: path),
                isDiff: true
            )
        case .web(let url)?:
            return Label(
                title: tab.flatMap { model.webPages.title(for: $0.id) } ?? url.host() ?? url.absoluteString,
                symbol: "globe",
                place: where_,
                project: project
            )
        case nil:
            return Label(title: "Tab", symbol: "questionmark", place: "")
        }
    }

    /// "Archipel/Views" for a file in the worktree, which says more than the project name when
    /// several files share one.
    private func relativeFolder(of path: String, in worktree: Worktree?) -> String? {
        guard let root = worktree?.path.path(percentEncoded: false) else { return nil }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let folder = (String(path.dropFirst(prefix.count)) as NSString).deletingLastPathComponent
        return folder.isEmpty ? worktree?.displayName : folder
    }

    /// The content itself, or an icon on the project's color while there is none yet (a file still
    /// loading) or none to show (a session that is not running).
    private func preview(_ label: Label) -> some View {
        let shape = RoundedRectangle(cornerRadius: SwitcherMetrics.previewRadius, style: .continuous)
        let tint = label.project.map { model.tint(of: $0).color } ?? .gray
        let content = switcher.previews[tabID]

        return ZStack {
            if let content {
                PreviewContent(preview: content)
                    .transition(.blurReplace)
            } else {
                ZStack {
                    LinearGradient(colors: [tint.opacity(0.28), tint.opacity(0.1)], startPoint: .top, endPoint: .bottom)
                    placeholderIcon(label)
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                }
                .transition(.blurReplace)
            }
        }
        .frame(width: SwitcherMetrics.previewSize.width, height: SwitcherMetrics.previewSize.height)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 2 : 0.5)
        }
        .overlay(alignment: .topLeading) {
            if isCurrent {
                Text("Current")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
                    .padding(6)
            }
        }
        .animation(.smooth(duration: 0.3), value: content == nil)
    }

    /// `.ts` and `.mts` are video to UTType, which would put a movie icon on TypeScript. Sniffing the
    /// bytes like the editor does is no option while drawing, and a video in a repo is the rare case.
    private static func iconType(for file: URL) -> UTType {
        switch file.pathExtension.lowercased() {
        case "ts", "mts", "cts": UTType("com.microsoft.typescript") ?? .sourceCode
        default: UTType(filenameExtension: file.pathExtension) ?? .data
        }
    }

    /// Sessions show their project, files the icon Finder gives them, with a diff badge on diffs.
    @ViewBuilder
    private func placeholderIcon(_ label: Label) -> some View {
        if let file = label.file {
            Image(nsImage: NSWorkspace.shared.icon(for: Self.iconType(for: file)))
                .resizable()
                .frame(width: 46, height: 46)
                .overlay(alignment: .bottomTrailing) {
                    if label.isDiff {
                        Image(systemName: "plus.forwardslash.minus")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(.tint, in: .circle)
                            .offset(x: 4, y: 2)
                    }
                }
        } else if let project = label.project {
            ProjectIconView(project: project, size: 40)
        }
    }
}

/// The preview area of a card. Text is tiny and cropped on the right rather than scaled down, so
/// it stays readable.
private struct PreviewContent: View {
    let preview: TabPreview

    private static let font = Font.system(size: 6.5, design: .monospaced)

    var body: some View {
        Group {
            switch preview {
            case .terminal(let lines):
                // A terminal grows from the bottom, so that is the end worth showing.
                text(lines.joined(separator: "\n"), alignment: .bottomLeading, fadeFrom: .top)
            case .text(let lines):
                text(lines.joined(separator: "\n"), alignment: .topLeading, fadeFrom: .bottom)
            case .image(let image):
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(10)
                    .frame(width: SwitcherMetrics.previewSize.width, height: SwitcherMetrics.previewSize.height)
                    .background(.background.secondary)
            case .diff(let lines):
                diff(lines)
            }
        }
        .accessibilityHidden(true)
    }

    private func text(_ string: String, alignment: Alignment, fadeFrom edge: UnitPoint) -> some View {
        Text(verbatim: string)
            .font(Self.font)
            .lineSpacing(0.5)
            .foregroundStyle(.primary.opacity(0.85))
            .fixedSize()
            .padding(8)
            // A fixed frame, not a flexible one: a flexible frame grows to the text's full width
            // and the card then shows the middle of each line.
            .frame(width: SwitcherMetrics.previewSize.width, height: SwitcherMetrics.previewSize.height, alignment: alignment)
            .mask {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.4)],
                    startPoint: edge,
                    endPoint: edge == .top ? .bottom : .top
                )
            }
            .background(Color(nsColor: .textBackgroundColor))
    }

    /// Each line gets a tinted band like in the diff view, so you can see where the change is even
    /// when the text is too small to read.
    private func diff(_ lines: [DiffPreviewLine]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The offset is the identity on purpose: lines repeat (blank context lines, closing
            // braces) and the preview has no line numbers to tell them apart.
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line.text.isEmpty ? " " : line.text)
                    .font(Self.font)
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 0.75)
                    .frame(width: SwitcherMetrics.previewSize.width, alignment: .leading)
                    .background(band(line.kind))
            }
        }
        .padding(.top, 6)
        .frame(width: SwitcherMetrics.previewSize.width, height: SwitcherMetrics.previewSize.height, alignment: .topLeading)
        .clipped()
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func band(_ kind: GitDiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.22)
        case .removed: .red.opacity(0.22)
        case .context: .clear
        }
    }
}

#if DEBUG
private func previewSwitcher(withContent: Bool) -> some View {
    let model = PanePreviews.model(selecting: PanePreviews.mixedTabs())
    let tabs = model.selectedWorktree?.panes.first?.tabs ?? []
    let claudeTab = model.workspace.tab(showing: PreviewFixtures.claudeSessionID)
    // Codex, the file, the diff, a session in another worktree, the review session.
    let candidates = [tabs[0], tabs[2], tabs[3], claudeTab, tabs[1]].compactMap(\.self).map(\.id)
    var previews: [ArchipelCore.Tab.ID: TabPreview] = [:]
    if withContent {
        previews[candidates[0]] = .terminal([
            "Running the cache tests", "", "  ✓ stores responses (12 ms)", "  ✓ evicts the oldest entry (3 ms)",
            "  ✓ survives a relaunch (48 ms)", "", "Allow `rm -rf build`?", "  1. Yes", "  2. No, and tell Codex what to do",
        ])
        previews[candidates[1]] = .text([
            "import Foundation", "", "/// Pulls remote changes and pushes local ones.", "actor SyncEngine {",
            "    private var pending: [Change] = []", "    private let cache: ResponseCache", "",
            "    func sync() async throws {", "        let remote = try await fetch()", "        try merge(remote)", "    }", "}",
        ])
        previews[candidates[2]] = .diff([
            DiffPreviewLine(kind: .context, text: "final class ResponseCache {"),
            DiffPreviewLine(kind: .removed, text: "    var entries: [URL: Data] = [:]"),
            DiffPreviewLine(kind: .added, text: "    private var entries: [URL: Entry] = [:]"),
            DiffPreviewLine(kind: .added, text: "    private let limit: Int"),
            DiffPreviewLine(kind: .context, text: ""),
            DiffPreviewLine(kind: .context, text: "    func response(for url: URL) -> Data? {"),
            DiffPreviewLine(kind: .removed, text: "        entries[url]"),
            DiffPreviewLine(kind: .added, text: "        entries[url]?.data"),
            DiffPreviewLine(kind: .context, text: "    }"),
        ])
        previews[candidates[3]] = .terminal(["Refactoring SyncEngine", "", "⏺ Update(Sources/Sync/SyncEngine.swift)", "  ⎿  Updated with 14 additions"])
    }
    let switcher = TabSwitcherModel()
    if var gesture = TabSwitch(candidates: candidates, current: candidates.first) {
        gesture.advance(by: 1)
        switcher.showForPreview(gesture, startedFrom: candidates.first, previews: previews)
    }
    return TabSwitcher()
        .environment(model)
        .environment(switcher)
        .frame(width: 1200, height: 360)
        .background(.windowBackground)
}

#Preview("With Content") {
    previewSwitcher(withContent: true)
}

#Preview("With Content, Dark") {
    previewSwitcher(withContent: true)
        .preferredColorScheme(.dark)
}

#Preview("Placeholders") {
    previewSwitcher(withContent: false)
}
#endif
