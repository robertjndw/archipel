import AppKit
import GitKit
import SwiftUI

/// What the primary button says and whether it can be pressed.
struct CommitControl: Equatable {
    enum Mode: Equatable { case commit, commitAll }

    var mode: Mode
    var hasChanges: Bool
    /// git refuses to commit with unmerged paths, and "Commit All" would get around that by staging
    /// the files with their conflict markers still in them.
    var hasConflicts: Bool
    var isEnabled: Bool

    init(status: GitStatus, message: String, isBusy: Bool) {
        hasChanges = !status.staged.isEmpty || !status.unstaged.isEmpty
        hasConflicts = status.unstaged.contains { $0.kind == .conflicted } || status.staged.contains { $0.kind == .conflicted }
        // With nothing staged, "Commit All" is the only thing a commit can mean.
        mode = status.staged.isEmpty && hasChanges ? .commitAll : .commit
        let hasMessage = !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        isEnabled = hasChanges && hasMessage && !isBusy && !hasConflicts
    }

    var title: LocalizedStringKey { mode == .commit ? "Commit" : "Commit All" }
}

/// The Changes tab's view of the one sync rule, see `GitSyncState`.
typealias SyncState = GitSyncState

extension GitSyncState {
    var canPush: Bool { canPush(from: .changesTab) }

    var pushTitle: String { pushTitle(from: .changesTab) }

    /// Whether Publish goes to the host's name sheet instead of pushing. The host offers that only
    /// while the branch has a name it made up, and a branch with an upstream is past naming.
    func asksForBranchName(offered: Bool) -> Bool { offered && !isPublished }

    /// With an ellipsis while Publish opens the name sheet first.
    func pushTitle(asksForBranchName: Bool) -> String {
        asksForBranchName ? String(localized: "Publish Branch…") : pushTitle
    }

    var help: LocalizedStringKey {
        if isDetached { return "HEAD is detached. Check out a branch to push." }
        if !isPublished {
            guard let publishRemote else {
                return hasRemote
                    ? "None of this repository's remotes is named origin. Push from a terminal to choose one."
                    : "This repository has no remote."
            }
            if let goneUpstream { return "\(goneUpstream) no longer exists. Publish this branch to \(publishRemote) again." }
            return "Publish this branch to \(publishRemote)."
        }
        if behind > 0 {
            return "The branch is \(behind) behind \(upstream ?? "its upstream"). Pull first, otherwise git rejects the push."
        }
        let target = upstream ?? String(localized: "the upstream")
        switch ahead {
        case 0: return "Nothing to push."
        case 1: return "Push 1 commit to \(target)."
        default: return "Push \(ahead) commits to \(target)."
        }
    }

    /// A String, not a key, because it's also the menu trigger's AppKit tooltip.
    var summary: String {
        if isDetached { return String(localized: "Detached HEAD") }
        guard let upstream else {
            if let goneUpstream { return String(localized: "\(goneUpstream) no longer exists") }
            return hasRemote ? String(localized: "Not published") : String(localized: "No remote")
        }
        if ahead == 0 && behind == 0 { return String(localized: "Up to date with \(upstream)") }
        return String(localized: "\(ahead) ahead, \(behind) behind \(upstream)")
    }
}

/// The main button under the message. Like in VS Code it commits while there are changes and
/// otherwise offers pull, push or publish. Pull and push are always in the header's sync menu too.
enum PrimaryAction: Equatable {
    case commit(CommitControl)
    /// `ahead` is only nonzero for a diverged branch, usually after someone force-pushed.
    case pull(commits: Int, ahead: Int, isEnabled: Bool)
    case push(commits: Int, isEnabled: Bool)
    case publish(isEnabled: Bool)

    init(commit: CommitControl, sync: SyncState) {
        if commit.hasChanges {
            self = .commit(commit)
        } else if sync.needsPull {
            // Pull before push: git rejects a push to an upstream that has moved on.
            self = .pull(commits: sync.behind, ahead: sync.ahead, isEnabled: sync.canPull)
        } else if sync.promotesPush {
            self = sync.isPublished
                ? .push(commits: sync.ahead, isEnabled: sync.canPush)
                : .publish(isEnabled: sync.canPush)
        } else {
            // Nothing to do, or nothing to do by default. A disabled Commit looks less alarming
            // than a disabled Push.
            self = .commit(commit)
        }
    }

    var isEnabled: Bool {
        switch self {
        case .commit(let control): control.isEnabled
        case .pull(_, _, let isEnabled), .push(_, let isEnabled), .publish(let isEnabled): isEnabled
        }
    }

    var activity: ChangesModel.Activity {
        switch self {
        case .commit: .commit
        case .pull: .pull
        case .push, .publish: .push
        }
    }

    // Spelled out instead of ^[…](inflect: true): the grammar engine takes "Commit" for a verb and
    // conjugates it, which gives "1 Commits" and "2 Commit", even when told it's a noun.
    var title: LocalizedStringKey {
        switch self {
        case .commit(let control): control.title
        case .pull(let commits, _, _): commits == 1 ? "Pull 1 Commit" : "Pull \(commits) Commits"
        case .push(let commits, _): commits == 1 ? "Push 1 Commit" : "Push \(commits) Commits"
        case .publish: "Publish Branch"
        }
    }

    /// Up for push, down for pull.
    var direction: SyncDirection {
        switch self {
        case .pull: .down
        case .commit, .push, .publish: .up
        }
    }

    var symbol: String? {
        switch self {
        case .commit: nil
        // A diverged branch shows just the two counts, VS Code style.
        case .pull(_, let ahead, _): ahead > 0 ? nil : "arrow.down"
        case .push: "arrow.up"
        case .publish: "icloud.and.arrow.up"
        }
    }
}

extension GitPullRequest {
    var symbol: String { state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull" }
}

/// Glass only while the button is enabled. A disabled glass button still draws a full-width
/// outline right under the message field, so while disabled it is only its dimmed title, at the
/// same height so nothing moves when it becomes enabled.
private struct PrimaryActionStyle: ViewModifier {
    let isEnabled: Bool

    /// The height of a large prominent glass button, so nothing below moves when it switches.
    private static let height: CGFloat = 29

    func body(content: Content) -> some View {
        if isEnabled {
            content.buttonStyle(.glassProminent)
        } else {
            content
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .frame(height: Self.height)
        }
    }
}

/// Pinned under the file list: message, the primary action and the pull request control.
struct CommitArea: View {
    @Bindable var model: ChangesModel
    /// Set by the host (the Commit… command) to put the cursor in the message field.
    @Binding var focusRequest: Bool
    /// Called instead of publishing when the host wants the branch named first.
    var publishBranch: (() -> Void)? = nil
    @FocusState private var messageFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Push and pull get their flying arrow; a commit gets a brief checkmark in place of the spinner.
    @State private var showsCommitDone = false

    var body: some View {
        let action = model.primaryAction

        VStack(alignment: .leading, spacing: 8) {
            TextField("Commit message", text: $model.message, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($messageFocused)
                .accessibilityIdentifier("changes.commitMessage")
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                // Half the one-line height (a 16pt line plus 7pt above and below), so a single
                // line is a capsule. Fixed rather than .capsule, which would keep rounding the
                // whole side as a longer message grows the field.
                .glassEffect(.regular, in: .rect(cornerRadius: 15))
                .disabled(model.activity == .commit)
                // `initial` too: the request usually arrives while the Changes tab is still being built.
                .onChange(of: focusRequest, initial: true) {
                    guard focusRequest else { return }
                    messageFocused = true
                    focusRequest = false
                }

            // Same row and control size, otherwise the PR button ends up with a smaller radius.
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    primaryButton(action)
                    pullRequestButton
                }
                .controlSize(.large)
                .animation(.smooth(duration: 0.2), value: model.pullRequest)
            }
        }
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func primaryButton(_ action: PrimaryAction) -> some View {
        let asksForName = model.syncState.asksForBranchName(offered: publishBranch != nil)
        return Button {
            if case .publish = action, asksForName, let publishBranch {
                publishBranch()
            } else {
                model.performPrimaryAction()
            }
        } label: {
            HStack(spacing: 6) {
                if showsCommitDone {
                    Image(systemName: "checkmark")
                        .transition(.symbolEffect)
                } else if let symbol = action.symbol {
                    SyncArrow(
                        systemName: symbol,
                        direction: action.direction,
                        isBusy: model.activity == action.activity,
                        completion: model.syncCompletion
                    )
                    .contentTransition(.symbolEffect(.replace))
                } else if model.activity == action.activity {
                    ProgressView().controlSize(.small)
                }
                if showsCommitDone {
                    // The button already describes the next step by now ("Push 1 Commit"), and a
                    // checkmark beside that would read as the push having happened.
                    Text("Committed")
                } else if case .pull(let behind, let ahead, _) = action, ahead > 0 {
                    DivergedCounts(behind: behind, ahead: ahead)
                } else if case .publish = action, asksForName {
                    Text(verbatim: model.syncState.pushTitle(asksForBranchName: true))
                } else {
                    Text(action.title)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .modifier(PrimaryActionStyle(isEnabled: action.isEnabled))
        .disabled(!action.isEnabled)
        .accessibilityIdentifier("changes.primaryAction")
        // Only while the field is focused and the button commits, so Cmd-Return never pushes.
        .keyboardShortcut(messageFocused && action.activity == .commit ? KeyboardShortcut(.return, modifiers: .command) : nil)
        .help(help(for: action))
        // The digits roll when a count changes ("Push 3 Commits"); a crossfade under Reduce Motion.
        .contentTransition(reduceMotion ? .interpolate : .numericText())
        .animation(.smooth(duration: 0.2), value: action)
        .onChange(of: model.commitCompletions) {
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { showsCommitDone = true }
        }
        // Keyed on the count, so a second commit while the mark is up restarts the wait.
        .task(id: model.commitCompletions) {
            guard showsCommitDone else { return }
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { showsCommitDone = false }
        }
    }

    private func help(for action: PrimaryAction) -> LocalizedStringKey {
        switch action {
        case .commit(let control) where control.hasConflicts: "Resolve the merge conflicts and stage the files before committing."
        case .commit(let control): control.mode == .commitAll ? "Stages all changes, then commits them." : "Commits the staged changes."
        case .pull(let behind, let ahead, _) where ahead > 0:
            "The branch has diverged from \(model.syncState.upstream ?? "its upstream") (\(behind) behind, \(ahead) ahead) and can't be fast-forwarded. Rebase or merge in a terminal."
        case .pull: "Fast-forwards to \(model.syncState.upstream ?? "the upstream"). Never merges or rebases."
        case .push, .publish: model.syncState.help
        }
    }

    @ViewBuilder
    private var pullRequestButton: some View {
        if let pullRequest = model.pullRequest {
            Button {
                NSWorkspace.shared.open(pullRequest.url)
            } label: {
                HStack(spacing: 4) {
                    // Not colored by state. Glass recolors tinted content for contrast, so the
                    // icon ended up a different color than the number.
                    Image(systemName: pullRequest.symbol)
                    Text("#\(pullRequest.number)").monospacedDigit()
                }
            }
            .buttonStyle(.glass)
            .fixedSize()
            .help(pullRequest.title)
            .accessibilityLabel("Pull Request #\(pullRequest.number)")
            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .trailing)))
        }
    }
}

/// Pull, push and fetch in the header next to Refresh, similar to Xcode's Integrate menu.
/// The label shows the ahead/behind counts.
///
/// Not a SwiftUI `Menu`: AppKit draws a menu's label as a static image, so symbol effects don't play,
/// and it only keeps the first label, which drops a count when the branch has diverged. A borderless
/// button looks like Refresh next to it and opens an NSMenu instead.
struct SyncMenu: View {
    let model: ChangesModel
    /// Called instead of publishing when the host wants the branch named first.
    var publishBranch: (() -> Void)? = nil
    @State private var anchor = MenuAnchor()

    var body: some View {
        let sync = model.syncState
        let isEnabled = !(sync.isDetached && !sync.canFetch)

        Button { showMenu(sync) } label: {
            label(sync)
                // Font and inset of a native menu button. The header itself uses callout.
                .font(.body)
                .padding(.horizontal, 3)
                .animation(.smooth(duration: 0.3), value: remoteActivity)
        }
        .buttonStyle(.borderless)
        // Monochrome like Refresh beside it.
        .foregroundStyle(.secondary)
        // Opens on mouse down like a native menu. The button underneath handles keyboard and VoiceOver.
        .overlay { MenuTrigger(anchor: anchor, tooltip: sync.summary, isEnabled: isEnabled) { showMenu(sync) } }
        .fixedSize()
        .disabled(!isEnabled)
        .accessibilityLabel("Sync")
        .accessibilityValue(Text(sync.summary))
    }

    private func showMenu(_ sync: SyncState) {
        guard let view = anchor.view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionMenuItem(String(localized: "Pull"), symbol: "arrow.down", isEnabled: sync.canPull, action: model.pull))
        let asksForName = sync.asksForBranchName(offered: publishBranch != nil)
        let push = asksForName ? publishBranch ?? model.push : model.push
        menu.addItem(ActionMenuItem(sync.pushTitle(asksForBranchName: asksForName), symbol: sync.isPublished ? "arrow.up" : "icloud.and.arrow.up", isEnabled: sync.canPush, action: push))
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(String(localized: "Fetch"), symbol: "arrow.triangle.2.circlepath", isEnabled: sync.canFetch, action: model.fetch))
        // 9 pt below the button is where a native pull-down puts its menu.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 9 : -9), in: view)
    }

    /// Commit progress already shows on the bottom button.
    private var remoteActivity: ChangesModel.Activity? {
        model.activity == .commit ? nil : model.activity
    }

    @ViewBuilder
    private func label(_ sync: SyncState) -> some View {
        ZStack {
            if let activity = remoteActivity {
                ActivitySymbol(activity: activity, completion: model.syncCompletion)
                    // No removal animation, a sent-off arrow is already gone at this point.
                    .transition(.identity)
            } else {
                idleLabel(sync)
                    // Delayed so it doesn't overlap the arrow flying off.
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.8)).animation(.smooth(duration: 0.3).delay(0.15)),
                        removal: .identity
                    ))
            }
        }
    }

    @ViewBuilder
    private func idleLabel(_ sync: SyncState) -> some View {
        if sync.ahead > 0 || sync.behind > 0 {
            HStack(spacing: 6) {
                if sync.behind > 0 { Label(String(sync.behind), systemImage: "arrow.down") }
                if sync.ahead > 0 { Label(String(sync.ahead), systemImage: "arrow.up") }
            }
            .labelStyle(SyncCountLabelStyle())
            .contentTransition(.numericText())
            .animation(.smooth, value: sync)
        } else {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

/// Lets the button reach the AppKit view it should open its menu from.
@MainActor
private final class MenuAnchor {
    weak var view: NSView?
}

/// Sits on top of the sync button and opens the menu on mouse down, like a native pull-down.
private struct MenuTrigger: NSViewRepresentable {
    let anchor: MenuAnchor
    let tooltip: String
    /// SwiftUI's `disabled` doesn't reach AppKit views, so the trigger checks this itself.
    let isEnabled: Bool
    let open: () -> Void

    final class TriggerView: NSView {
        var open: () -> Void = {}
        var isEnabled = true
        override func mouseDown(with event: NSEvent) {
            if isEnabled { open() }
        }
        // Not focusable or visible to VoiceOver: the SwiftUI button underneath covers both.
        override func isAccessibilityElement() -> Bool { false }
    }

    func makeNSView(context: Context) -> TriggerView { TriggerView() }

    func updateNSView(_ view: TriggerView, context: Context) {
        view.open = open
        view.isEnabled = isEnabled
        view.toolTip = tooltip
        anchor.view = view
    }
}

private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String, isEnabled: Bool, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(runHandler), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        self.isEnabled = isEnabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func runHandler() { handler() }
}

/// Shown instead of a spinner while a remote action runs.
private struct ActivitySymbol: View {
    let activity: ChangesModel.Activity
    let completion: SyncCompletion
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        switch activity {
        case .fetch:
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate.clockwise.wholeSymbol, options: .repeat(.continuous), isActive: !reduceMotion)
        case .pull:
            SyncArrow(systemName: "arrow.down", direction: .down, isBusy: true, completion: completion)
        case .push, .commit:
            SyncArrow(systemName: "arrow.up", direction: .up, isBusy: true, completion: completion)
        }
    }
}

enum SyncDirection: Equatable { case up, down }

/// A push or pull that just landed.
struct SyncCompletion: Equatable {
    var count: Int
    var direction: SyncDirection
}

/// Wiggles while its action runs and flies off in its direction when the action succeeds. By the time
/// the model is idle the label has usually dropped the arrow; if it hasn't, the arrow comes back.
struct SyncArrow: View {
    let systemName: String
    let direction: SyncDirection
    let isBusy: Bool
    let completion: SyncCompletion

    /// Crouch plus flight. The model waits this long before refreshing so the arrow can leave.
    static let sendOffDuration = Duration.milliseconds(450)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase = Phase.resting

    private enum Phase { case resting, crouched, sent }

    var body: some View {
        Image(systemName: systemName)
            .symbolEffect(direction == .up ? .wiggle.up : .wiggle.down, options: .repeat(.continuous), isActive: isBusy && phase == .resting && !reduceMotion)
            .offset(y: direction == .up ? offset : -offset)
            .scaleEffect(phase == .sent ? 0.7 : 1, anchor: direction == .up ? .bottom : .top)
            .blur(radius: phase == .sent ? 1 : 0)
            .opacity(phase == .sent ? 0 : 1)
            // The primary button swaps between the pull and push arrow, so only fly off when the
            // finished action went this arrow's way.
            .onChange(of: completion) {
                guard completion.direction == direction else { return }
                sendOff()
            }
            .onChange(of: isBusy) {
                guard !isBusy, phase != .resting else { return }
                withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .smooth(duration: 0.3)) { phase = .resting }
            }
    }

    private var offset: CGFloat {
        switch phase {
        case .resting: 0
        case .crouched: 1.5
        case .sent: reduceMotion ? 0 : -14
        }
    }

    private func sendOff() {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) { phase = .sent }
            return
        }
        withAnimation(.easeOut(duration: 0.12)) {
            phase = .crouched
        } completion: {
            // Ease in, so it speeds up as it leaves.
            withAnimation(.timingCurve(0.5, 0, 0.75, 0.4, duration: 0.32)) { phase = .sent }
        }
    }
}

/// Same look as the sync menu's label.
private struct DivergedCounts: View {
    let behind: Int
    let ahead: Int

    var body: some View {
        // Full-size arrows, so the button doesn't look smaller than its Push and Pull variants.
        HStack(spacing: 6) {
            Label(String(behind), systemImage: "arrow.down")
            Label(String(ahead), systemImage: "arrow.up")
        }
        .labelStyle(SyncCountLabelStyle())
        .monospacedDigit()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(behind) to pull, \(ahead) to push")
    }
}

/// Full-size arrow, spaced like the image and title of a native button.
private struct SyncCountLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

#if DEBUG
@MainActor
private func previewCommitArea(_ title: String, _ model: ChangesModel) -> some View {
    PreviewVariant(title) {
        CommitArea(model: model, focusRequest: .constant(false))
    }
}

#Preview("Commit") {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            previewCommitArea("Staged changes, no message", .previewSample(PreviewSamples.stagedOnly))
            previewCommitArea("Staged changes, message", .previewSample(PreviewSamples.stagedOnly, message: "Fix the session switcher"))
            previewCommitArea("Nothing staged: commits everything", .previewSample(PreviewSamples.unstagedOnly, message: "Fix the session switcher"))
            previewCommitArea("Long message", .previewSample(
                PreviewSamples.stagedOnly,
                message: "Fix the session switcher\n\nThe list kept sessions that had already closed, so picking one opened an empty pane. Forget a session as soon as its process exits."
            ))
            previewCommitArea("Committing", .previewSample(PreviewSamples.stagedOnly, message: "Fix the session switcher", activity: .commit))
        }
        .padding(.vertical)
    }
    .frame(width: 300, height: 640)
    .background(Color.inspectorBackground)
}

#Preview("Sync and Pull Request") {
    ScrollView {
        VStack(alignment: .leading, spacing: 8) {
            previewCommitArea("Clean, up to date", .previewSample(PreviewSamples.synced()))
            previewCommitArea("Behind", .previewSample(PreviewSamples.synced(behind: 3)))
            previewCommitArea("Diverged", .previewSample(PreviewSamples.synced(ahead: 2, behind: 3)))
            previewCommitArea("Ahead, open pull request", .previewSample(PreviewSamples.synced(ahead: 1), pullRequest: PreviewSamples.pullRequest(.open)))
            previewCommitArea("Pushing, draft pull request", .previewSample(
                PreviewSamples.synced(ahead: 2), activity: .push, pullRequest: PreviewSamples.pullRequest(.open, isDraft: true)
            ))
            previewCommitArea("Not published", .previewSample(PreviewSamples.synced(upstream: nil)))
            previewCommitArea("Upstream deleted", .previewSample(
                GitStatus(branch: "fix/login", staged: [], unstaged: [], goneUpstream: "origin/fix/login")
            ))
            previewCommitArea("Merged pull request", .previewSample(PreviewSamples.synced(), pullRequest: PreviewSamples.pullRequest(.merged)))
        }
        .padding(.vertical)
    }
    .frame(width: 300, height: 760)
    .background(Color.inspectorBackground)
}

#Preview("Sync and Pull Request, Dark") {
    VStack(alignment: .leading, spacing: 8) {
        previewCommitArea("Ahead, open pull request", .previewSample(PreviewSamples.synced(ahead: 1), pullRequest: PreviewSamples.pullRequest(.open)))
        previewCommitArea("Staged changes, message", .previewSample(PreviewSamples.stagedOnly, message: "Fix the session switcher"))
    }
    .padding(.vertical)
    .frame(width: 300)
    .background(Color.inspectorBackground)
    .preferredColorScheme(.dark)
}

// Runs on a loop since the canvas doesn't take clicks for this preview.
#Preview("Push Send-Off") {
    @Previewable @State var pushes = SyncCompletion(count: 0, direction: .up)
    @Previewable @State var isBusy = false

    Button {} label: {
        HStack(spacing: 6) {
            SyncArrow(systemName: "arrow.up", direction: .up, isBusy: isBusy, completion: pushes)
            Text("Push 2 Commits")
        }
        .frame(maxWidth: .infinity)
    }
    .buttonStyle(.glassProminent)
    .controlSize(.large)
    .padding()
    .frame(width: 300)
    .task {
        while !Task.isCancelled {
            isBusy = true
            try? await Task.sleep(for: .seconds(1.5))
            pushes.count += 1
            try? await Task.sleep(for: .seconds(1))
            isBusy = false
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
}

#Preview("Sync Menu") {
    VStack(alignment: .leading, spacing: 12) {
        PreviewVariant("Up to date") { SyncMenu(model: .previewSample(PreviewSamples.synced())) }
        PreviewVariant("2 ahead, 3 behind") { SyncMenu(model: .previewSample(PreviewSamples.synced(ahead: 2, behind: 3))) }
        PreviewVariant("Fetching") { SyncMenu(model: .previewSample(PreviewSamples.synced(), activity: .fetch)) }
        PreviewVariant("Pulling") { SyncMenu(model: .previewSample(PreviewSamples.synced(behind: 3), activity: .pull)) }
        PreviewVariant("Detached, no remote") { SyncMenu(model: .previewSample(PreviewSamples.synced(upstream: nil, branch: nil), hasRemote: false)) }
    }
    .padding()
}
#endif
