import AppKit
import EditorUI

/// Asks before a link from a Markdown preview leaves the worktree: to another app, or to a file
/// outside it. The Markdown can come from a repository nobody has read, and a custom URL scheme
/// can run a shortcut or mount a share, so the question shows the whole destination and which
/// app would get it. What is asked, and what is refused, is decided by `PreviewLinkPolicy`.
@MainActor
enum ExternalLinkConfirmation {
    /// `root` is the worktree the previewed document belongs to.
    static func open(_ url: URL, root: URL?) {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: url)
        let name = handler.map { FileManager.default.displayName(atPath: $0.path(percentEncoded: false)) }
        ask(PreviewLinkPolicy.prompt(forOpening: url, handler: handler, handlerName: name, root: root)) {
            guard let handler else { return }
            // To the app the question named, not to whichever one is registered by now.
            NSWorkspace.shared.open([url], withApplicationAt: handler, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }

    /// `file` is the resolved destination; `open` runs once the user agrees.
    static func openFile(_ file: URL, open: @escaping () -> Void) {
        ask(PreviewLinkPolicy.prompt(forFileOutsideRoot: file), then: open)
    }

    private static func ask(_ prompt: PreviewLinkPolicy.Prompt, then open: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.detail
        guard prompt.canOpen else {
            present(alert) { _ in }
            return
        }
        // No default button, so a Return that was meant for something else does not open it.
        alert.addButton(withTitle: "Open").keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        // With Full Keyboard Access the first button would start out focused, and Space presses
        // whatever has the focus. The alert has to lay itself out before it accepts another choice.
        alert.layout()
        alert.window.initialFirstResponder = cancel
        present(alert) { response in
            if response == .alertFirstButtonReturn { open() }
        }
    }

    private static func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}
