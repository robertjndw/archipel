import ACPKit
import EditorUI
import SwiftUI
import UISupport

/// One chat session: its transcript, whatever state it is in, and the composer.
public struct ChatView: View {
    private let session: ChatSession
    private let actions: ChatViewActions
    private let agentSymbol: Image

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var paneWidth: CGFloat = 900

    /// `agentSymbol` is the agent's logo, shown before the first message and while the agent is
    /// being set up. The app owns the artwork, so it passes the image in.
    public init(session: ChatSession, actions: ChatViewActions = ChatViewActions(), agentSymbol: Image = Image(systemName: "sparkles")) {
        self.session = session
        self.actions = actions
        self.agentSymbol = agentSymbol
    }

    public var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { paneWidth = $0 }
            .environment(\.chatGutter, ChatMetrics.gutter(forPaneWidth: paneWidth))
            .environment(\.chatAgentSymbol, agentSymbol)
            .environment(\.chatWorkingDirectory, session.configuration?.workingDirectory)
            .environment(\.chatAgentName, session.agentName)
            .environment(\.chatDiffCache, session.diffCache)
            .environment(\.markdownPathLinker, session.pathLinker)
            // Links in replies go where the app sends links, not straight to the browser.
            .environment(\.openURL, OpenURLAction { url in
                actions.openLink(url)
                return .handled
            })
            // From the first moment the chat is on screen, so the status line can say how long
            // a turn has been running even after its tab was switched away from and back.
            .task(id: ObjectIdentifier(session)) { session.viewState.follow(session) }
    }

    @ViewBuilder private var content: some View {
        switch session.phase {
        case let .starting(step):
            ChatStartingView(step: step, cancel: { session.cancelStart() })
                .transition(.opacity)
        case let .failed(failure):
            ChatFailureView(failure: failure, session: session, actions: actions)
                .transition(.opacity)
        case .ready:
            conversation(ending: nil)
        case let .ended(ending):
            conversation(ending: ending)
        }
    }

    /// The transcript over the composer. With nothing said yet there is no transcript, and the
    /// composer sits in the middle of the pane under a welcome. It is the same composer in the
    /// same stack either way, so on the first send it travels down to its place, and keeps the
    /// cursor while it does.
    private func conversation(ending: ChatEnding?) -> some View {
        let isEmpty = session.transcript.items.isEmpty && ending == nil
        return VStack(spacing: 0) {
            if isEmpty {
                Spacer(minLength: 0)
                ChatWelcome(agentName: session.agentName)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            } else {
                ChatTranscriptView(session: session, actions: actions)
                    .transition(.opacity)
            }
            if let ending {
                ChatEndedBar(ending: ending, actions: actions)
                    .transition(.opacity)
            } else {
                dock
                    .chatColumn(maxWidth: isEmpty ? ChatMetrics.welcomeComposerWidth : ChatMetrics.columnWidth)
                    .padding(.bottom, 12)
            }
            if isEmpty {
                // A little more room below than above: the optical middle is above the real one.
                Spacer(minLength: 0)
                Spacer(minLength: 0)
                    .frame(maxHeight: 60)
            }
        }
        // Reduce Motion: no travel. The composer is at the bottom as soon as the first message is.
        .animation(reduceMotion ? nil : Motion.selection, value: isEmpty)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty, ending == nil else { return false }
            session.addAttachments(files)
            session.requestComposerFocus()
            return true
        }
    }

    /// The composer and what is docked on top of it: a passing notice, then the permission
    /// request or, when nothing is being asked, the plan. One thing at a time above the composer
    /// keeps the bottom of the pane calm.
    private var dock: some View {
        let request = session.permissionRequests.first
        let choices = request.map { PermissionChoices(options: $0.options) }

        return VStack(spacing: 8) {
            if let notice = session.notice {
                NoticeCapsule(message: notice) { session.dismissNotice() }
                    .transition(.opacity)
            }
            if let request {
                PermissionCard(
                    request: request, agentName: session.agentName, queued: session.permissionRequests.count,
                    respond: { choice in respond(to: request, with: choice) }
                )
                // A new card for each request, so the next one in the queue does not inherit the
                // collapsed preview of the one before.
                .id(request.id)
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)).combined(with: .offset(y: 12)))
            } else if !session.transcript.plan.isEmpty {
                PlanView(entries: session.transcript.plan)
                    .transition(.opacity)
            }
            ChatComposer(
                session: session,
                actions: actions,
                allowPermission: answer(request, with: choices?.primary),
                rejectPermission: answer(request, with: choices?.reject)
            )
        }
        .animation(reduceMotion ? nil : Motion.selection, value: request?.id)
        .animation(reduceMotion ? nil : Motion.hover, value: session.notice)
        .animation(reduceMotion ? nil : Motion.disclosure, value: session.transcript.plan.isEmpty)
    }

    private func answer(_ request: ChatPermissionRequest?, with choice: PermissionChoice?) -> (@MainActor () -> Void)? {
        guard let request, let choice else { return nil }
        return { respond(to: request, with: choice) }
    }

    private func respond(to request: ChatPermissionRequest, with choice: PermissionChoice) {
        actions.userInteracted()
        Task { await session.respond(to: request, optionId: choice.optionId) }
    }
}
