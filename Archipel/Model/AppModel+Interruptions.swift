import AgentKit
import ArchipelCore
import Foundation

/// What is known about the turns of one Claude session that the user may have interrupted.
struct InterruptionWatch {
    /// When the main agent's hooks last reported something.
    var lastEventAt: Date?
    /// The transcript entry of the interruption that was already acted on.
    var handledID: String?
    var check: Task<Void, Never>?
    /// A cue came in while `check` was running, too late for the looks it had left to be sure
    /// of seeing what the cue was about.
    var cueDuringCheck = false
    /// Where Claude writes the conversation, from the first hook or status line that says so.
    /// Kept apart from the context window, which is unknown until the first reply.
    var transcriptPath: String?
    /// The transcript as it was at the last look that got an answer, so one that has not been
    /// written to since is not read again.
    var lastLook: (path: String, stamp: ClaudeTranscript.Stamp)?
}

/// Claude runs no hook when the user stops a turn with Esc or dismisses a permission prompt, so
/// nothing would ever take the session out of "working" or "waiting for you": Stay Awake stays on,
/// quitting asks, and the worktree's other results are held back. Claude does end the conversation
/// on a line of its own in the transcript then, and it redraws its status line, retitles the
/// terminal and clears its progress around that moment. Those are the cue to read the transcript.
/// Nothing is polled: the only timer is the few seconds of looks that follow a cue. And a turn
/// is never given up on for being quiet, since a long tool call writes no such line.
extension AppModel {
    /// The first look comes shortly after the cue, the second covers a cue that came before the
    /// line was written.
    private static let interruptionCheckDelays: [Duration] = [.seconds(1), .seconds(3)]
    /// How long after its last look a check looks once more, when a cue came in meanwhile.
    private static let interruptionFollowUpDelay: Duration = .seconds(3)
    /// A hook can still be on its way when the interruption is written. Anything later than this
    /// means the conversation went on after it.
    private static let interruptionTolerance: TimeInterval = 2

    func checkForInterruptionSoon(_ id: Session.ID) {
        guard mayBeInterrupted(id) else { return }
        guard interruptionWatches[id]?.check == nil else {
            // The line this cue announces may land after the running check's last look.
            interruptionWatches[id]?.cueDuringCheck = true
            return
        }
        interruptionWatches[id, default: InterruptionWatch()].check = Task { [weak self] in
            var delays = Self.interruptionCheckDelays
            while !delays.isEmpty {
                for delay in delays {
                    try? await Task.sleep(for: delay)
                    guard !Task.isCancelled, let self else { return }
                    if await self.settleInterruption(of: id) {
                        self.interruptionWatches[id]?.cueDuringCheck = false
                        self.interruptionWatches[id]?.check = nil
                        return
                    }
                }
                guard !Task.isCancelled, let self else { return }
                // Titles and progress keep coming during a turn, so a working session settles
                // into one look per follow-up delay, and most of those find the file unchanged.
                let cued = self.interruptionWatches[id]?.cueDuringCheck == true
                self.interruptionWatches[id]?.cueDuringCheck = false
                delays = cued ? [Self.interruptionFollowUpDelay] : []
            }
            self?.interruptionWatches[id]?.check = nil
        }
    }

    func forgetInterruptions(of id: Session.ID) {
        interruptionWatches.removeValue(forKey: id)?.check?.cancel()
    }

    /// Only a Claude the app launched: its hooks and status line are what tell the app where the
    /// transcript is.
    private func mayBeInterrupted(_ id: Session.ID) -> Bool {
        guard workspace.session(id: id)?.agent == .claude, interruptionWatches[id]?.transcriptPath != nil else { return false }
        return activity(for: id).status.isMidTurn
    }

    /// True when there is nothing left to look for.
    private func settleInterruption(of id: Session.ID) async -> Bool {
        guard mayBeInterrupted(id), let path = interruptionWatches[id]?.transcriptPath else { return true }
        let lastStamp = interruptionWatches[id]?.lastLook.flatMap { $0.path == path ? $0.stamp : nil }
        let look = await Task.detached(priority: .utility) {
            ClaudeTranscript.lookForInterruption(at: URL(fileURLWithPath: path), since: lastStamp)
        }.value
        // The turn may have ended or the conversation changed while the file was read.
        guard !Task.isCancelled, mayBeInterrupted(id), interruptionWatches[id]?.transcriptPath == path else { return true }
        // An unchanged file ends on what the last look already weighed: nothing, an interruption
        // that was acted on, or one older than the turn, which only gets older.
        guard case .read(let found, let stamp) = look else { return false }
        interruptionWatches[id]?.lastLook = stamp.map { (path: path, stamp: $0) }
        guard let found, found.id != interruptionWatches[id]?.handledID else { return false }
        // Only an interruption of the turn the hooks reported counts. A resumed conversation can
        // end on an old one, and a prompt typed right after one reaches the hooks before it
        // reaches the transcript.
        guard let lastEvent = interruptionWatches[id]?.lastEventAt,
              found.date >= lastEvent.addingTimeInterval(-Self.interruptionTolerance)
        else { return false }
        interruptionWatches[id, default: InterruptionWatch()].handledID = found.id
        apply(.turnInterrupted, to: id)
        return true
    }
}
