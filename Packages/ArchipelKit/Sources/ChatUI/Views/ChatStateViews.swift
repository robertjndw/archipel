import ACPKit
import SwiftUI
import UISupport

// MARK: Starting

/// The chat getting ready. Quick steps are a spinner and a word; installing takes long enough to
/// say what is going on.
///
/// A start that takes a while offers Cancel. A sign-in offers it at once: it waits on the user,
/// who may have closed the browser it opened.
struct ChatStartingView: View {
    let step: ChatSession.StartStep
    let cancel: @MainActor () -> Void

    /// Long enough that a normal start, even a slow restore, never shows it.
    static let cancelDelay: Duration = .seconds(8)

    @Environment(\.chatAgentSymbol) private var agentSymbol
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasTakenAWhile = false

    var body: some View {
        content
            // Once for the whole start: the view stays while the steps change.
            .task {
                do {
                    try await Task.sleep(for: Self.cancelDelay)
                } catch {
                    return
                }
                withAnimation(reduceMotion ? nil : Motion.disclosure) { hasTakenAWhile = true }
            }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case let .installing(agentName, fraction):
            ContentUnavailableView {
                Label {
                    Text("Setting Up \(agentName)")
                } icon: {
                    agentSymbol
                }
            } description: {
                Text("Downloading what \(agentName) needs to run as a chat. This happens once.")
            } actions: {
                VStack(spacing: 16) {
                    InstallProgress(fraction: fraction)
                    cancelButton
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preparing, .connecting:
            progress("Starting…")
        case .restoringHistory:
            progress("Restoring Conversation…")
        case .signingIn:
            progress("Signing In…")
        }
    }

    private func progress(_ label: LocalizedStringKey) -> some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            cancelButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Always laid out, so nothing moves when it fades in.
    private var cancelButton: some View {
        let isShown = hasTakenAWhile || step == .signingIn
        return Button("Cancel", action: cancel)
            .buttonStyle(.glass)
            .opacity(isShown ? 1 : 0)
            .allowsHitTesting(isShown)
            .accessibilityHidden(!isShown)
            .accessibilityIdentifier("chat.cancelStart")
    }
}

private struct InstallProgress: View {
    let fraction: Double?

    var body: some View {
        VStack(spacing: 6) {
            if let fraction {
                ProgressView(value: min(max(fraction, 0), 1))
                Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }
        }
        .frame(width: 220)
    }
}

// MARK: Failed

/// The chat cannot go on without the user: a sign-in, a missing Node.js, or a start that failed.
struct ChatFailureView: View {
    let failure: ChatFailure
    let session: ChatSession
    let actions: ChatViewActions

    @State private var showsDetails: Bool

    /// Previews pass `showsDetails` to start with the agent's error output open.
    init(failure: ChatFailure, session: ChatSession, actions: ChatViewActions, showsDetails: Bool = false) {
        self.failure = failure
        self.session = session
        self.actions = actions
        _showsDetails = State(initialValue: showsDetails)
    }

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: symbol)
        } description: {
            Text(verbatim: failure.message)
        } actions: {
            VStack(spacing: 16) {
                GlassEffectContainer {
                    // Side by side when they fit; a narrow pane stacks them rather than cut one off.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { buttons }
                        VStack(spacing: 8) { buttons }
                    }
                }
                .controlSize(.large)
                if let details = failure.details, !details.isEmpty {
                    FailureDetails(details: details, isShown: $showsDetails)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var symbol: String {
        switch failure.reason {
        case .signInRequired: "person.crop.circle"
        case .nodeMissing: "shippingbox"
        case .installFailed, .couldNotStart, .unsupportedProtocolVersion: "exclamationmark.triangle"
        }
    }

    @ViewBuilder private var buttons: some View {
        switch failure.reason {
        case let .signInRequired(agentMethods, terminalMethods):
            ForEach(Array(agentMethods.enumerated()), id: \.element.id) { index, method in
                Button(method.name) {
                    Task { await session.authenticate(methodId: method.id) }
                }
                .prominence(index == 0)
                .help(method.description ?? "")
                .accessibilityIdentifier("chat.signIn")
            }
            if !terminalMethods.isEmpty, let signInInTerminal = actions.signInInTerminal {
                Button("Sign In in Terminal", action: signInInTerminal)
                    .prominence(agentMethods.isEmpty)
                    .accessibilityIdentifier(agentMethods.isEmpty ? "chat.signIn" : "chat.signInInTerminal")
            }
            if agentMethods.isEmpty, terminalMethods.isEmpty || actions.signInInTerminal == nil {
                // Nothing here can sign in, so at least let the user try again once they have
                // signed in some other way.
                tryAgain.prominence(true)
            }
        case .nodeMissing:
            tryAgain.prominence(true)
            Button("Get Node.js") {
                if let url = URL(string: "https://nodejs.org/") { actions.openLink(url) }
            }
            .prominence(false)
        case .installFailed, .couldNotStart, .unsupportedProtocolVersion:
            tryAgain.prominence(true)
            Button("Agent Settings…", action: actions.openAgentSettings)
                .prominence(false)
        }
    }

    private var tryAgain: some View {
        Button("Try Again") {
            Task { await session.retry() }
        }
        .accessibilityIdentifier("chat.retry")
    }
}

private extension View {
    /// The one prominent button of a state, or a plain glass one next to it.
    @ViewBuilder func prominence(_ isProminent: Bool) -> some View {
        if isProminent {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.glass)
        }
    }
}

/// The agent's own error output, for whoever wants to know more than the message says.
private struct FailureDetails: View {
    let details: String
    @Binding var isShown: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            // Not a DisclosureGroup: its label hugs the leading edge, and everything else in
            // this state is centered.
            Button {
                withAnimation(reduceMotion ? nil : Motion.disclosure) { isShown.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text("Details")
                    DisclosureChevron(isExpanded: isShown)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityValue(isShown ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("chat.failureDetails")

            if isShown {
                CappedHeight(maximum: 160) {
                    ScrollView {
                        Text(verbatim: details)
                            .font(ChatMetrics.codeFont)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
                .background(.quinary, in: .rect(cornerRadius: ChatMetrics.blockRadius, style: .continuous))
                .frame(maxWidth: 440)
                .transition(.opacity)
            }
        }
        .font(.callout)
    }
}

// MARK: Ended

/// Takes the composer's place once the agent process is gone. The transcript above stays.
struct ChatEndedBar: View {
    let ending: ChatEnding
    let actions: ChatViewActions

    @State private var showsDetails = false

    var body: some View {
        HStack(spacing: 12) {
            Label(ending.message, systemImage: ending.isClean ? "stop.circle" : "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if let details = ending.details, !details.isEmpty {
                Button("Details", systemImage: "info.circle") { showsDetails = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Show Details")
                    .popover(isPresented: $showsDetails, arrowEdge: .top) {
                        CappedHeight(maximum: 240) {
                            ScrollView {
                                Text(verbatim: details)
                                    .font(ChatMetrics.codeFont)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(14)
                            }
                        }
                        .frame(width: 460)
                    }
            }
            Spacer(minLength: 0)
            Button("Close", systemImage: "xmark", action: actions.close)
                .buttonStyle(.glass)
                .accessibilityIdentifier("chat.close")
            Button("Restart", systemImage: "arrow.clockwise", action: actions.restart)
                .buttonStyle(.glassProminent)
                .accessibilityIdentifier("chat.restart")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: Empty

/// Before anything was said: the agent's logo and its name above the composer.
struct ChatWelcome: View {
    let agentName: String

    @Environment(\.chatAgentSymbol) private var agentSymbol

    var body: some View {
        VStack(spacing: 14) {
            agentSymbol
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(height: 48)
                .accessibilityHidden(true)
            Text("Chat with \(agentName)")
                .font(.title2.weight(.semibold))
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Chat with \(agentName)")
    }
}

// MARK: Notice

/// A passing problem, said once near the composer. Goes away by itself or on a click.
struct NoticeCapsule: View {
    let message: String
    let dismiss: @MainActor () -> Void

    var body: some View {
        Button(action: dismiss) {
            Label {
                Text(verbatim: message)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            } icon: {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .capsule)
        .help("Dismiss")
        .accessibilityHint("Dismisses the message")
        .accessibilityIdentifier("chat.notice")
        .task(id: message) {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }
}
