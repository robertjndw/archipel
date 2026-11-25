import Foundation
import Observation

/// An edit's diff as the transcript shows it: the counts and the first lines.
struct DiffAnalysis: Equatable, Sendable {
    var stats: LineDiff.Stats
    /// The unified diff, up to `LineDiff.maximumShownLines` lines.
    var lines: [DiffLine]
    /// Lines of the diff past those in `lines`.
    var hiddenLineCount: Int
    /// The texts were too long to compare, so every old line counts as removed and every new one
    /// as added. The counts say little then.
    var isApproximate: Bool
}

/// Diffs worked out once per distinct edit, off the main actor.
///
/// Agents send whole files as the old and new text of an edit, and comparing two large files takes
/// long enough to stall the transcript. A view's body runs again on every hover and every streamed
/// update, so rows ask here instead: the first request starts the work in the background, and
/// every later one for the same texts, from any row or card of the chat, shares its result.
@MainActor
final class DiffCache {
    /// The texts themselves: an edit sent twice, as a permission card and then as a tool call,
    /// is one entry. Equal strings usually share storage, so comparing them is cheap.
    struct Key: Hashable, Sendable {
        var oldText: String?
        var newText: String
    }

    /// One edit's analysis, nil until it is ready. Observed on its own, so a finished diff only
    /// redraws the views that show it.
    @MainActor @Observable
    final class Entry {
        fileprivate(set) var analysis: DiffAnalysis?
        @ObservationIgnored fileprivate var lastUse = 0
    }

    /// Bounded by count rather than by what is left in the transcript: a lazy transcript only
    /// asks for rows on screen, so the least recently asked for are the ones nobody is looking at.
    let capacity: Int
    private let analyze: @Sendable (Key) -> DiffAnalysis
    private var entries: [Key: Entry] = [:]
    private var uses = 0
    /// How many analyses were started, for tests.
    private(set) var analysesStarted = 0

    init(capacity: Int = 64, analyze: @escaping @Sendable (Key) -> DiffAnalysis = { LineDiff.analysis(old: $0.oldText, new: $0.newText) }) {
        self.capacity = capacity
        self.analyze = analyze
    }

    /// The entry for `key`, starting its analysis when it is new. Safe to call from a body: what
    /// it changes is not observed.
    func entry(for key: Key) -> Entry {
        uses += 1
        if let entry = entries[key] {
            entry.lastUse = uses
            return entry
        }
        let entry = Entry()
        entry.lastUse = uses
        entries[key] = entry
        analysesStarted += 1
        let analyze = analyze
        Task { [weak entry] in
            let analysis = await Task.detached(priority: .userInitiated) { analyze(key) }.value
            entry?.analysis = analysis
        }
        if entries.count > capacity, let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse })?.key {
            entries[oldest] = nil
        }
        return entry
    }

    var count: Int { entries.count }

    /// For views that are shown without a chat, such as a lone diff in a preview.
    static let fallback = DiffCache()
}

extension LineDiff {
    /// Lines past this are summed up in one line. A view per line is fine for an edit, not for a
    /// whole generated file.
    static let maximumShownLines = 600

    /// Everything the transcript shows of one edit, from one pass over the texts.
    static func analysis(old: String?, new: String, context: Int = 3) -> DiffAnalysis {
        let (changes, isApproximate) = changesAndPrecision(old: old, new: new)
        var stats = Stats(added: 0, removed: 0)
        for change in changes {
            switch change.kind {
            case .added: stats.added += 1
            case .removed: stats.removed += 1
            case .context, .gap: break
            }
        }
        let all = trimmed(changes, context: context)
        return DiffAnalysis(
            stats: stats,
            lines: Array(all.prefix(maximumShownLines)),
            hiddenLineCount: max(0, all.count - maximumShownLines),
            isApproximate: isApproximate
        )
    }
}
