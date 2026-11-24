import ArchipelCore
import Foundation

/// The tabs of Close Other Tabs or Close Tabs to the Right that are still to close, behind the
/// tab the user is being asked about.
struct QueuedTabCloses {
    /// Tells one request from the next, for a continuation that wakes up after its request was
    /// replaced.
    let id = UUID()
    /// The tab whose question holds the rest back, nil once it was answered. Only an answer about
    /// this tab continues them.
    var asking: Tab.ID?
    var rest: [Tab.ID]
}

extension AppModel {
    /// Each tab goes through `close(tab:)`, so unsaved files and busy sessions still ask. The
    /// dialogs hold one question at a time, so the tabs behind the first one that raised a
    /// question wait for its answer: closing or saving goes on with them, Cancel leaves them open.
    ///
    /// Cancel is not reported to the model. The tabs it left stay queued until the next
    /// `close(tab:)`, which drops them, and nothing but an answer to the question they wait
    /// behind picks them up; that question cannot come back without a `close(tab:)` first.
    func close(tabs ids: [Tab.ID]) {
        var rest = ids[...]
        while let id = rest.popFirst() {
            // Skips a tab that went away while an earlier question was up, and drops what an
            // earlier request left queued.
            close(tab: id)
            if isAskingAboutClosing(id) {
                if !rest.isEmpty { queuedTabCloses = QueuedTabCloses(asking: id, rest: Array(rest)) }
                return
            }
        }
    }

    /// Goes on with the tabs that waited for the answer about this one. Does nothing after an
    /// answer to any other question, such as one tab closed by itself.
    func continueQueuedTabCloses(after id: Tab.ID) {
        guard var queued = queuedTabCloses, queued.asking == id else { return }
        queued.asking = nil
        queuedTabCloses = queued
        Task { [weak self] in
            // The dialog that was just answered is still on its way out, and it clears the
            // question it was shown for when it is gone. One raised before that would be lost.
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, let current = self.queuedTabCloses, current.id == queued.id, current.asking == nil else { return }
            self.queuedTabCloses = nil
            // Something else is being asked by now. Closing around it would replace that question.
            guard self.tabAwaitingCloseDecision == nil, self.sessionAwaitingInterruptDecision == nil else { return }
            self.close(tabs: current.rest)
        }
    }

    private func isAskingAboutClosing(_ id: Tab.ID) -> Bool {
        if tabAwaitingCloseDecision?.id == id { return true }
        if case .close(let tab)? = sessionAwaitingInterruptDecision?.action { return tab.id == id }
        return false
    }
}
