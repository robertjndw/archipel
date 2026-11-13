import AppKit
import ArchipelCore
import SwiftUI

/// Edits a project's setup and run scripts.
struct ProjectSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var setup = ""
    @State private var run = ""

    var body: some View {
        Form {
            Section {
                ScriptEditor(text: $setup)
            } header: {
                Text("Setup script")
            } footer: {
                Text("Runs once in each new worktree, for example to install dependencies or copy .env from the main checkout.")
            }
            Section {
                ScriptEditor(text: $run)
            } header: {
                Text("Run script")
            } footer: {
                Text("Started with Run (⌘R), for example a dev server. Running again restarts it.")
            }
            Section {
                Text("""
                Scripts run with zsh in the worktree folder, as their own session tab. These variables are set:
                ARCHIPEL_WORKTREE_PATH: the worktree folder
                ARCHIPEL_ROOT_PATH: the project's main checkout
                ARCHIPEL_BRANCH: the worktree's branch, when it has one
                """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .navigationTitle("\(project.name) Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.saveScripts(ProjectScripts(setup: setup, run: run), of: project.id)
                    dismiss()
                }
            }
        }
        .onAppear {
            setup = project.scripts.setup
            run = project.scripts.run
        }
    }
}

/// A plain NSTextView, because SwiftUI's TextEditor follows the system's smart quotes and dashes
/// setting, which would silently turn `"$VAR"` and `--flag` into something no shell understands.
private struct ScriptEditor: View {
    @Binding var text: String

    var body: some View {
        ScriptTextView(text: $text)
            .frame(minHeight: 90, maxHeight: 180)
            .accessibilityLabel("Script")
    }
}

private struct ScriptTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.string = text
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
