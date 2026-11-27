import AgentKit
import AppKit
import ArchipelCore
import SwiftUI

/// A row of picture tiles with a caption under each, like the appearance choice in System Settings.
struct TilePicker<Value: Hashable, Preview: View>: View {
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String
    @ViewBuilder let preview: (Value) -> Preview
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    VStack(spacing: 4) {
                        preview(option)
                            .clipShape(.rect(cornerRadius: Chrome.controlRadius - 3, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Chrome.controlRadius - 3, style: .continuous)
                                    .strokeBorder(.separator, lineWidth: 0.5)
                            }
                            // Gap between picture and ring so a dark preview doesn't swallow it.
                            // Outer radius = inner radius + padding.
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: Chrome.controlRadius, style: .continuous)
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                                    .opacity(isSelected ? 1 : 0)
                            }
                        Text(title(option))
                            .font(.callout)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(reduceMotion ? nil : Motion.selection, value: selection)
        // Without this VoiceOver reads every tile as the row's label instead of its own title.
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(title(option)).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
        }
    }
}

/// A miniature Archipel window in a fixed light or dark look, for the appearance tiles.
/// System shows both halves, the way macOS draws its own Auto tile.
struct AppearancePreview: View {
    let appearance: AppSettings.Appearance

    var body: some View {
        switch appearance {
        case .light: MiniWindow(isDark: false)
        case .dark: MiniWindow(isDark: true)
        case .system:
            ZStack {
                MiniWindow(isDark: false)
                MiniWindow(isDark: true)
                    .mask(alignment: .trailing) {
                        Rectangle().frame(width: Self.size.width / 2)
                    }
            }
        }
    }

    static let size = CGSize(width: 76, height: 50)

    private struct MiniWindow: View {
        let isDark: Bool

        var body: some View {
            let wallpaper = isDark
                ? [Color(red: 0.16, green: 0.20, blue: 0.36), Color(red: 0.08, green: 0.09, blue: 0.18)]
                : [Color(red: 0.62, green: 0.78, blue: 0.98), Color(red: 0.86, green: 0.82, blue: 0.97)]
            let window = isDark ? Color(white: 0.17) : Color(white: 0.99)
            let sidebar = isDark ? Color(white: 0.24) : Color(white: 0.91)
            let line = isDark ? Color(white: 0.38) : Color(white: 0.80)

            ZStack(alignment: .topLeading) {
                LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 2) {
                            Circle().fill(.red)
                            Circle().fill(.yellow)
                            Circle().fill(.green)
                        }
                        .frame(height: 3.5)
                        .padding(.bottom, 2)
                        RoundedRectangle(cornerRadius: 1).fill(Color.accentColor).frame(width: 14, height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 11, height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 13, height: 3)
                        Spacer(minLength: 0)
                    }
                    .padding(4)
                    .frame(width: 24, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    .background(sidebar)
                    VStack(alignment: .leading, spacing: 3) {
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 26, height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 18, height: 3)
                        RoundedRectangle(cornerRadius: 1).fill(line).frame(width: 22, height: 3)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 13)
                    .padding(.leading, 5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(window)
                }
                .clipShape(.rect(cornerRadius: 3))
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 0.5)
                .padding(.top, 9)
                .padding(.leading, 10)
                // Runs off the bottom right edge, like a window bigger than the tile.
                .frame(width: size.width + 6, height: size.height + 6, alignment: .topLeading)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }

        private var size: CGSize { AppearancePreview.size }
    }
}

/// How the Claude usage reads at the bottom of the window in each style, with made-up numbers.
struct UsageDisplayPreview: View {
    let display: AppSettings.UsageDisplay
    let fill: AppSettings.UsageBarFill

    var body: some View {
        HStack(spacing: 5) {
            Text("Claude")
                .foregroundStyle(.secondary)
            switch display {
            case .numbers:
                HStack(spacing: 3) {
                    Text("5h").foregroundStyle(.tertiary)
                    Text("42%").foregroundStyle(.secondary)
                }
                HStack(spacing: 3) {
                    Text("7d").foregroundStyle(.tertiary)
                    Text("18%").foregroundStyle(.secondary)
                }
            case .bars:
                VStack(spacing: 2) {
                    UsageBar(usedPercent: 42, fill: fill, height: 4)
                    UsageBar(usedPercent: 18, fill: fill, height: 3)
                }
                .frame(width: 44)
            }
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .frame(width: 124, height: 34)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The status bar as its menu leaves it, drawn by the status bar's own layout and item
/// views. Sessions and limits are made up, so every item shows even before an agent has replied.
/// Resources and the cup are the real ones: they report on the Mac, which is there either way.
struct StatusBarPreview: View {
    let settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Made once, so the countdown runs down instead of starting over on every redraw.
    @State private var cache = PromptCacheState(lastRequestAt: .now.addingTimeInterval(-12 * 60), ttl: 3600)
    @State private var reading = ProviderUsage(
        provider: .claude,
        windows: [
            UsageWindow(usedPercent: 42, windowMinutes: 300, resetsAt: .now.addingTimeInterval(2 * 3600)),
            UsageWindow(usedPercent: 18, windowMinutes: 7 * 24 * 60, resetsAt: .now.addingTimeInterval(3 * 86400)),
        ],
        updatedAt: .now
    )

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Chrome.controlRadius, style: .continuous)
        let shown = AppSettings.StatusBarItem.allCases.filter(settings.shows)
        StatusBarStrip(items: shown) { item in
            switch item {
            case .usage: UsageItem(reading: reading, now: .now, display: settings.usageDisplay, fill: settings.usageBarFill)
            case .context:
                ContextLabel(
                    modelName: settings.shows(.model) ? "Opus 4.7" : nil,
                    usedPercent: settings.shows(.context) ? 61 : nil,
                    cache: settings.shows(.context) ? cache : nil, display: settings.usageDisplay, fill: settings.usageBarFill
                )
            case .model: EmptyView()
            case .agents: AgentsLabel(summary: AttentionSummary(working: 2))
            case .resources: ResourcesItem()
            case .stayAwake: StayAwakeButton()
            }
        }
        .frame(height: 2 * Chrome.bottomLineInset)
        .frame(maxWidth: .infinity)
        // A picture of the bar: its buttons would otherwise open popovers and change the cup's mode.
        .allowsHitTesting(false)
        .background(Chrome.windowSurface, in: shape)
        .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status bar preview")
        .accessibilityValue(shown.isEmpty ? "Empty" : shown.map(\.title).formatted(.list(type: .and)))
        .accessibilityHint("Its actions show or hide each item.")
        .statusBarMenu(settings)
        .accessibilityIdentifier("settings.statusBarPreview")
        .animation(reduceMotion ? nil : Motion.disclosure, value: settings.hiddenStatusBarItems)
        .animation(reduceMotion ? nil : Motion.disclosure, value: settings.usageDisplay)
    }
}

/// Real sidebar rows with sample data, using the current density and row options. Right-click to
/// choose what rows show, same as the status bar preview.
struct SidebarRowsPreview: View {
    let settings: AppSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Default sidebar width, so the rows truncate like the real ones.
    static let width: CGFloat = 250

    // Never read from disk. A row only shows the folder name when it has nothing else to show.
    private static let root = URL(fileURLWithPath: "/Users/you/orbit-worktrees", isDirectory: true)
    private static let waiting = Worktree(
        path: root.appending(path: "onboarding", directoryHint: .isDirectory),
        branch: "feat/onboarding-copy",
        sessions: [Session(title: "Claude Code", agentTitle: "Rewrite onboarding copy", agent: .claude)]
    )
    private static let changed = Worktree(
        path: root.appending(path: "cache-expiry", directoryHint: .isDirectory),
        branch: "fix/cache-expiry"
    )
    private static let waitingActivity = SessionActivity(
        status: .needsAttention(.question), unread: true, lastMessage: "Should the welcome screen mention pricing?"
    )
    private static let changedGit = WorktreeGitState(
        changedFiles: 3, ahead: 2, insertions: 40, deletions: 9,
        pullRequest: PullRequestBadge(number: 42, state: .open)
    )

    var body: some View {
        let options = WorktreeRowContent.Options(
            showsGitStatus: settings.showsGitStatusInSidebar,
            showsPullRequests: settings.showsPullRequests,
            showsMessages: settings.showsAgentMessagesInSidebar
        )
        let shape = RoundedRectangle(cornerRadius: Chrome.controlRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            row(Self.waiting, activity: Self.waitingActivity, git: nil, options: options)
            row(Self.changed, activity: nil, git: Self.changedGit, options: options)
        }
        .padding(.vertical, 6)
        .padding(.trailing, 10)
        .frame(width: Self.width, alignment: .leading)
        .environment(\.sidebarDensity, settings.sidebarDensity)
        // Display only, otherwise the rows' hover buttons would start real sessions.
        .allowsHitTesting(false)
        .background(.background.secondary, in: shape)
        .overlay { shape.strokeBorder(.separator, lineWidth: 0.5) }
        .contentShape(shape)
        .contextMenu {
            ForEach(Self.parts, id: \.title) { part in
                Toggle(part.title, isOn: binding(part.setting))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sidebar preview")
        .accessibilityValue(shownParts)
        .accessibilityHint("Its actions show or hide each part of a row.")
        // VoiceOver can't open a menu that only a right-click brings up.
        .accessibilityActions {
            ForEach(Self.parts, id: \.title) { part in
                Button((settings[keyPath: part.setting] ? "Hide " : "Show ") + part.title) {
                    settings[keyPath: part.setting].toggle()
                }
            }
        }
        .accessibilityIdentifier("settings.sidebarPreview")
        .animation(reduceMotion ? nil : Motion.disclosure, value: options)
        .animation(reduceMotion ? nil : Motion.disclosure, value: settings.sidebarDensity)
    }

    private func row(_ worktree: Worktree, activity: SessionActivity?, git: WorktreeGitState?, options: WorktreeRowContent.Options) -> some View {
        SidebarWorktreeRow(
            worktree: worktree,
            content: WorktreeRowContent(worktree: worktree, activity: activity, git: git, options: options),
            sessions: [],
            isSelected: false,
            tint: .accentColor,
            removing: .constant(nil),
            renaming: .constant(nil)
        )
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding { settings[keyPath: keyPath] } set: { settings[keyPath: keyPath] = $0 }
    }

    /// The parts of a row the preview can show or hide, for its menu and its VoiceOver actions.
    private static let parts: [(title: String, setting: ReferenceWritableKeyPath<AppSettings, Bool>)] = [
        ("Git Status", \.showsGitStatusInSidebar),
        ("Pull Requests", \.showsPullRequests),
        ("Agent Messages", \.showsAgentMessagesInSidebar),
    ]

    private var shownParts: String {
        let shown = Self.parts.filter { settings[keyPath: $0.setting] }.map { $0.title.localizedLowercase }
        guard let first = shown.first else { return "Branch names only" }
        let list = shown.formatted(.list(type: .and))
        // Sentence case: only the list's first word starts with a capital.
        return first.prefix(1).localizedUppercase + list.dropFirst()
    }
}

extension NSImage {
    /// The Finder icon of an app or folder at menu size. A copy, because the workspace may hand out
    /// a shared instance and resizing that would shrink it everywhere.
    static func menuIcon(forFile path: String) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path).copy() as! NSImage
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }
}

/// A sliver of the sidebar at each density: a project header and its worktrees drawn as bars, so
/// the tiles compare how much fits rather than what the rows say.
struct SidebarDensityPreview: View {
    let density: AppSettings.SidebarDensity

    var body: some View {
        VStack(alignment: .leading, spacing: rowGap) {
            project(selectedRow: true)
            project(selectedRow: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .padding(.top, 5)
        .frame(width: AppearancePreview.size.width, height: AppearancePreview.size.height, alignment: .topLeading)
        .background(.background.secondary)
        .clipped()
    }

    private func project(selectedRow: Bool) -> some View {
        VStack(alignment: .leading, spacing: rowGap) {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor).frame(width: 5, height: 5)
                bar(width: 22, height: 3, style: .primary)
            }
            .padding(.top, headerGap)
            row(width: 28, isSelected: selectedRow)
            row(width: 20, isSelected: false)
        }
    }

    private func row(width: CGFloat, isSelected: Bool) -> some View {
        HStack(alignment: .top, spacing: 3) {
            Circle().fill(.tertiary).frame(width: 3, height: 3).padding(.top, 0.5)
            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 4) {
                    bar(width: width, height: 2.5, style: .secondary)
                    if density == .compact {
                        Spacer(minLength: 0)
                        bar(width: 8, height: 2, style: .tertiary)
                    }
                }
                if density != .compact {
                    bar(width: width * 0.7, height: 2, style: .tertiary)
                }
            }
        }
        .padding(.vertical, rowPadding)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 2))
    }

    private func bar(width: CGFloat, height: CGFloat, style: some ShapeStyle) -> some View {
        Capsule().fill(style).frame(width: width, height: height)
    }

    private var rowGap: CGFloat { density == .spacious ? 1.5 : 0.5 }
    private var rowPadding: CGFloat {
        switch density {
        case .compact: 1
        case .comfortable: 1.5
        case .spacious: 2.5
        }
    }
    private var headerGap: CGFloat {
        switch density {
        case .compact: 0
        case .comfortable: 1
        case .spacious: 3
        }
    }
}

/// Two panes side by side in each pane style, the second one dimmed the way an unfocused pane is.
struct PaneStylePreview: View {
    let style: AppSettings.PaneStyle

    private var isComfortable: Bool { style == .comfortable }

    var body: some View {
        let gap: CGFloat = isComfortable ? 3 : 0
        HStack(spacing: gap) {
            pane(lines: [24, 16, 20], isDimmed: false)
            if !isComfortable { Divider() }
            pane(lines: [14, 22, 10], isDimmed: true)
        }
        .padding(gap)
        .frame(width: AppearancePreview.size.width, height: AppearancePreview.size.height)
        .background(Chrome.windowSurface)
    }

    /// One surface from the tab row down, with the selected tab as the only mark in the row.
    private func pane(lines: [CGFloat], isDimmed: Bool) -> some View {
        let surface = Color(nsColor: .textBackgroundColor)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Capsule()
                    .fill(.quaternary)
                    .opacity(isDimmed ? 0 : 1)
                    .frame(width: 14, height: 5)
                    .overlay { Capsule().fill(.secondary).frame(width: 8, height: 2) }
                Capsule().fill(.tertiary).frame(width: 8, height: 2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 3)
            .frame(height: 10)
            VStack(alignment: .leading, spacing: 2.5) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, width in
                    Capsule().fill(.secondary).frame(width: width, height: 2.5)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(surface)
        .overlay { surface.opacity(isDimmed ? Chrome.unfocusedPaneDim : 0) }
        .clipShape(.rect(cornerRadius: isComfortable ? 4 : 0, style: .continuous))
    }
}

#if DEBUG
private struct ComponentGallery: View {
    @State private var appearance = AppSettings.Appearance.system
    @State private var density = AppSettings.SidebarDensity.comfortable
    @State private var paneStyle = AppSettings.PaneStyle.comfortable
    @State private var usage = AppSettings.UsageDisplay.bars
    @State private var fill = AppSettings.UsageBarFill.used

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            column(isEnabled: true)
            column(isEnabled: false)
        }
        .padding(24)
        .background(.background)
    }

    private func column(isEnabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEnabled ? "Enabled" : "Disabled").font(.headline)
            labeled("TilePicker with AppearancePreview") {
                TilePicker(selection: $appearance, options: AppSettings.Appearance.allCases, title: \.title) {
                    AppearancePreview(appearance: $0)
                }
            }
            labeled("TilePicker with SidebarDensityPreview") {
                TilePicker(selection: $density, options: AppSettings.SidebarDensity.allCases, title: \.title) {
                    SidebarDensityPreview(density: $0)
                }
            }
            labeled("TilePicker with PaneStylePreview") {
                TilePicker(selection: $paneStyle, options: AppSettings.PaneStyle.allCases, title: \.title) {
                    PaneStylePreview(style: $0)
                }
            }
            labeled("TilePicker with UsageDisplayPreview, \(fill.title.lowercased())") {
                TilePicker(selection: $usage, options: AppSettings.UsageDisplay.allCases, title: \.title) {
                    UsageDisplayPreview(display: $0, fill: fill)
                }
            }
            Picker("Bars show", selection: $fill) {
                ForEach(AppSettings.UsageBarFill.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .disabled(!isEnabled)
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

#Preview("Components, light") {
    ComponentGallery()
        .preferredColorScheme(.light)
}

#Preview("Components, dark") {
    ComponentGallery()
        .preferredColorScheme(.dark)
}
#endif
