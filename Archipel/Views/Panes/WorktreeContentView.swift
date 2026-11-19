import AgentKit
import ArchipelCore
import EditorUI
import SwiftUI
import TerminalKit

/// The narrowest a pane gets when the divider next to it is dragged.
private let minimumPaneWidth: CGFloat = 260

/// The content area of the selected worktree: its panes next to each other.
struct WorktreeContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(LayoutDefaults.showsInspector) private var showsInspector = true
    let isSidebarCollapsed: Bool
    let toggleSidebar: () -> Void

    var body: some View {
        if let worktree = model.selectedWorktree {
            let style = model.settings.paneStyle
            Group {
                if #available(macOS 27.2, *) {
                    HSplitView {
                        ForEach(worktree.panes) { pane in
                            paneView(pane, in: worktree, style: style)
                                .frame(minWidth: minimumPaneWidth, maxWidth: .infinity, maxHeight: .infinity)
                                .ignoresSafeArea(.container, edges: .top)
                                .snapsSplitDividerToCenter(enabled: pane.id == worktree.panes.first?.id)
                                .hidesSplitDivider(style == .comfortable)
                        }
                    }
                } else {
                    PaneStack(panes: worktree.panes, showsHairline: style == .compact) { pane in
                        paneView(pane, in: worktree, style: style)
                            .ignoresSafeArea(.container, edges: .top)
                    }
                }
            }
            .background {
                Chrome.windowSurface
                    .ignoresSafeArea(.container, edges: .top)
            }
            .ignoresSafeArea(.container, edges: .top)
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "sidebar.left",
                description: Text("Choose a worktree in the sidebar, or add a project to this island.")
            )
            // ContentUnavailableView only takes its ideal height, so without this the status bar
            // ends up halfway up the window.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension WorktreeContentView {
    private func paneView(_ pane: Pane, in worktree: Worktree, style: AppSettings.PaneStyle) -> some View {
        PaneView(
            worktree: worktree,
            pane: pane,
            isFocused: pane.id == worktree.focusedPane?.id,
            showsSidebarToggle: isSidebarCollapsed && pane.id == worktree.panes.first?.id,
            toggleSidebar: toggleSidebar
        )
        .modifier(PaneCard(
            style: style,
            isFirst: pane.id == worktree.panes.first?.id,
            isLast: pane.id == worktree.panes.last?.id,
            hasColumnBefore: !isSidebarCollapsed,
            hasColumnAfter: showsInspector
        ))
    }
}

/// The comfortable pane style: each pane a rounded card on the window surface. No border: the card
/// is the color of its content, and the gap is all that separates two of them.
///
/// The gaps come from padding inside each pane rather than from the split itself, so the same
/// modifier works in `HSplitView` and in `PaneStack`, and the split divider keeps its place (and
/// its drag) in the middle of the gap, with its hairline hidden. Neighbours each give half the gap,
/// which keeps the divider centered for the snap.
///
/// Next to the sidebar or the inspector the outer card gives up its gap: those columns sit on the
/// same surface and keep their own content inset, which already makes about the room two cards
/// leave between them. Only against the window edge does the card need the gap itself.
private struct PaneCard: ViewModifier {
    let style: AppSettings.PaneStyle
    let isFirst: Bool
    let isLast: Bool
    let hasColumnBefore: Bool
    let hasColumnAfter: Bool
    @Environment(\.windowCornerRadius) private var windowRadius

    // One modifier chain for both styles rather than a branch: a branch would give the pane a new
    // identity on every switch and remount the terminals inside it.
    func body(content: Content) -> some View {
        let isCard = style == .comfortable
        let gap = isCard ? Chrome.paneGap : 0
        // A plain rounded rectangle rather than ConcentricRectangle, so every corner gets the same
        // radius and it comes from the window's real corner radius instead of a fallback value.
        let radius = isCard ? Chrome.paneRadius(inWindowWithRadius: windowRadius) : 0
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .clipShape(shape)
            .padding(EdgeInsets(
                top: gap,
                leading: isFirst ? (hasColumnBefore ? 0 : gap) : gap / 2,
                bottom: gap,
                trailing: isLast ? (hasColumnAfter ? 0 : gap) : gap / 2
            ))
    }
}

/// Stands in for `HSplitView` before macOS 27.2. On 27.0.1 an `HSplitView` in the detail column
/// asks for more room than the window has once a second pane is open, and the sidebar ends up
/// partly outside the window. 27.2.1 lays it out fine; 27.1 was never tried, so it gets this too.
///
/// The GeometryReader is what prevents it: the panes inside report no minimum width to the
/// columns around them.
private struct PaneStack<Content: View>: View {
    let panes: [Pane]
    /// Off in the comfortable style, where the gap between the cards already parts them.
    let showsHairline: Bool
    @ViewBuilder let content: (Pane) -> Content

    /// Each pane's share of the width. A pane that was never resized counts as 1.
    @State private var weights: [Pane.ID: CGFloat] = [:]
    /// The widths of the two panes next to the divider being dragged, as they were when the drag began.
    @State private var dragOrigin: (leading: CGFloat, trailing: CGFloat)?

    private static var dividerWidth: CGFloat { 1 }
    /// How far to either side of the hairline a drag may start.
    private static var grabMargin: CGFloat { 4 }

    var body: some View {
        GeometryReader { proxy in
            let widths = widths(fitting: proxy.size.width)
            HStack(spacing: 0) {
                ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                    content(pane)
                        .frame(width: widths[index])
                        .frame(maxHeight: .infinity)
                    if index < panes.count - 1 {
                        divider(after: index, widths: widths)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
        }
    }

    private func weight(of pane: Pane) -> CGFloat { weights[pane.id] ?? 1 }

    private func widths(fitting total: CGFloat) -> [CGFloat] {
        let available = max(0, total - Self.dividerWidth * CGFloat(panes.count - 1))
        let sum = panes.reduce(0) { $0 + weight(of: $1) }
        guard sum > 0 else { return panes.map { _ in 0 } }
        return panes.map { available * weight(of: $0) / sum }
    }

    private func divider(after index: Int, widths: [CGFloat]) -> some View {
        Divider()
            .opacity(showsHairline ? 1 : 0)
            .overlay {
                Color.clear
                    .frame(width: Self.dividerWidth + 2 * Self.grabMargin)
                    .contentShape(.rect)
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let origin = dragOrigin ?? (widths[index], widths[index + 1])
                                dragOrigin = origin
                                resize(index, origin: origin, by: drag.translation.width)
                            }
                            .onEnded { _ in dragOrigin = nil }
                    )
            }
            // Above the pane that follows, which would otherwise take the clicks on its side of the hairline.
            .zIndex(1)
    }

    /// Moves width between the two panes at the divider. Their combined share stays what it was, so
    /// the other panes keep their widths.
    private func resize(_ index: Int, origin: (leading: CGFloat, trailing: CGFloat), by offset: CGFloat) {
        let pair = origin.leading + origin.trailing
        guard pair > 0 else { return }
        // Two panes squeezed under twice the minimum can only share what there is.
        let minimum = min(minimumPaneWidth, pair / 2)
        let leading = min(max(origin.leading + offset, minimum), pair - minimum)
        let share = weight(of: panes[index]) + weight(of: panes[index + 1])
        weights[panes[index].id] = share * leading / pair
        weights[panes[index + 1].id] = share * (pair - leading) / pair
    }
}

private struct PaneView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let worktree: Worktree
    let pane: Pane
    let isFocused: Bool
    let showsSidebarToggle: Bool
    let toggleSidebar: () -> Void

    /// A single pane has nothing to stand out from.
    private var isDimmed: Bool { !isFocused && worktree.panes.count > 1 }

    /// The tab row and the card take the color of what the pane shows, so they read as one surface.
    /// A terminal also dims the way Ghostty dims its own splits. Everything else is drawn on the
    /// text background and fades into it.
    private var surface: PaneSurface {
        if case .session = pane.selectedTab?.content, let colors = model.terminalColors {
            let background = colors.background
            return PaneSurface(
                color: Color(background),
                veil: Color(colors.unfocusedSplitFill),
                veilOpacity: 1 - colors.unfocusedSplitOpacity,
                // Where black and white text have the same contrast.
                colorScheme: background.luminance < 0.18 ? .dark : .light
            )
        }
        let text = Color(nsColor: .textBackgroundColor)
        return PaneSurface(color: text, veil: text, veilOpacity: Chrome.unfocusedPaneDim, colorScheme: nil)
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let surface = surface
        VStack(spacing: 0) {
            PaneTabBar(
                worktree: worktree,
                pane: pane,
                isFocused: isFocused,
                showsSidebarToggle: showsSidebarToggle,
                toggleSidebar: toggleSidebar,
                background: surface.color
            )
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(surface.color)
        .overlay {
            // So the eye finds the pane that takes the keys. It must never take a click: the click
            // is what focuses the pane, and the terminal under it needs it too.
            surface.veil
                .opacity(isDimmed ? surface.veilOpacity : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .animation(reduceMotion ? nil : Motion.hover, value: isDimmed)
        }
        // A dark terminal in a light window needs light text and dark glass in its tab row, and
        // the other way round. Always set, so a change of tab never changes the view's identity.
        .environment(\.colorScheme, surface.colorScheme ?? colorScheme)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            model.paneFrames[pane.id] = frame
        }
        .onDisappear { model.paneFrames[pane.id] = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch pane.selectedTab?.content {
        case .session(let id):
            if let tab = pane.selectedTab { SessionContent(sessionID: id, tabID: tab.id) }
        case .file(let url):
            FileEditor(url: url, store: model.documents)
        case .diff(let path, let staged):
            if model.isGitAvailable {
                DiffViewer(
                    root: worktree.path,
                    path: path,
                    staged: staged,
                    comments: model.reviewComments,
                    targets: model.reviewTargets(in: worktree),
                    onSend: { model.sendReviewComments(in: worktree.id, to: $0) },
                    onOpenFile: { model.openFile($0, in: worktree.id, preview: false) }
                )
            } else {
                // The viewer runs git of its own as soon as it is on screen, and a diff tab can be
                // restored from the last launch. Without the developer tools every such call
                // brings up the system's install dialog.
                ContentUnavailableView {
                    Label("Git Is Not Installed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(AppModel.gitMissingMessage)
                }
            }
        case .web(let url):
            if let tab = pane.selectedTab { WebTabView(tabID: tab.id, url: url) }
        case nil:
            ContentUnavailableView {
                Label("No Tabs", systemImage: "terminal")
            } description: {
                Text("Start an agent or a shell in \(worktree.displayName), or open a file from the inspector.")
            } actions: {
                GlassEffectContainer {
                    HStack(spacing: 8) {
                        ForEach(AgentDefinition.builtIns) { agent in
                            let canStart = model.canStartSession(with: agent)
                            Button(agent.displayName, symbol: agent.symbolName) {
                                model.newSession(in: worktree.id, agent: agent, pane: pane.id)
                            }
                            .disabled(!canStart)
                            .help(canStart ? "" : agent.missingCommandHint)
                        }
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }
}

private struct PaneSurface {
    var color: Color
    /// Laid over a pane without focus at `veilOpacity`.
    var veil: Color
    var veilOpacity: Double
    /// Set when the surface is not in the window's own light or dark, like a dark terminal in a
    /// light window.
    var colorScheme: ColorScheme?
}

private extension Color {
    init(_ rgb: TerminalColors.RGB) {
        self.init(.sRGB, red: rgb.red, green: rgb.green, blue: rgb.blue)
    }
}

private struct SessionContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let sessionID: Session.ID
    let tabID: ArchipelCore.Tab.ID

    var body: some View {
        let activity = model.activity(for: sessionID)
        let exitCode: Int32? = if case .exited(let code) = activity.status, model.terminals[sessionID] != nil { code } else { nil }
        Group {
            if let terminal = model.terminals[sessionID] {
                TerminalView(session: terminal)
                    // A new identity per session, so SwiftUI swaps the hosted
                    // terminal view instead of reusing one representable.
                    .id(sessionID)
            } else if let failure = model.launchFailures[sessionID] {
                ContentUnavailableView {
                    Label("Could Not Start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again") { model.restartSession(sessionID) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                    Button("Agent Settings…") {
                        SettingsView.select(.agents)
                        openSettings()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // The animation stays in here, so the bar fades in while the terminal above it takes
            // its new height at once instead of reflowing its lines on every frame.
            ZStack {
                if let exitCode {
                    ExitedBar(code: exitCode) {
                        model.restartSession(sessionID)
                    } close: {
                        model.close(tab: tabID)
                    }
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : Motion.hover, value: exitCode)
        }
    }
}

/// Sits below the terminal rather than over it, so the last lines of output
/// stay readable.
private struct ExitedBar: View {
    let code: Int32
    let restart: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(
                code == 0 ? "This session has ended." : "This session exited with code \(code).",
                systemImage: code == 0 ? "stop.circle" : "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Close", systemImage: "xmark", action: close)
                .buttonStyle(.glass)
            Button("Restart", systemImage: "arrow.clockwise", action: restart)
                .buttonStyle(.glassProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }
}

#if DEBUG
// Previews have no terminal engine, so a session tab shows the spinner it shows while starting.

#Preview("Session Starting") {
    WorktreeContentView(isSidebarCollapsed: false, toggleSidebar: {})
        .environment(AppModel.preview())
        .frame(width: 900, height: 500)
}

#Preview("Could Not Start") {
    WorktreeContentView(isSidebarCollapsed: false, toggleSidebar: {})
        .environment(AppModel.launchFailurePreview())
        .frame(width: 900, height: 500)
}

#Preview("Split Panes") {
    WorktreeContentView(isSidebarCollapsed: false, toggleSidebar: {})
        .environment(PanePreviews.model(selecting: PanePreviews.split()))
        .frame(width: 1000, height: 500)
}

#Preview("Split Panes, Compact") {
    let model = PanePreviews.model(selecting: PanePreviews.split())
    model.settings.paneStyle = .compact
    return WorktreeContentView(isSidebarCollapsed: false, toggleSidebar: {})
        .environment(model)
        .frame(width: 1000, height: 500)
}

#Preview("No Tabs") {
    WorktreeContentView(isSidebarCollapsed: true, toggleSidebar: {})
        .environment(PanePreviews.model(selecting: PreviewFixtures.blogWorktree))
        .frame(width: 900, height: 500)
}

#Preview("Nothing Selected") {
    WorktreeContentView(isSidebarCollapsed: false, toggleSidebar: {})
        .environment(AppModel.emptyPreview())
        .frame(width: 700, height: 400)
}

#Preview("Exited Bar") {
    VStack(spacing: 0) {
        ExitedBar(code: 0) {} close: {}
        ExitedBar(code: 1) {} close: {}
        ExitedBar(code: 1) {} close: {}
            .environment(\.colorScheme, .dark)
    }
    .frame(width: 600)
}
#endif
