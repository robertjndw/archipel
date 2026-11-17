import AppKit
import ArchipelCore
import Darwin
import Foundation
import Observation
import TerminalKit

/// CPU and memory per terminal, and the processes that outlive the tab that started them.
///
/// Every few seconds this reads the user's process table and attributes each process to the
/// terminal it came from (see `ProcessAttribution`). With no terminal open and nothing left
/// running there is nobody to attribute to, and only Archipel's own figures are read. When a tab closes or restarts, whatever of
/// its processes is still alive a few seconds later is listed as left running. Nothing is shown
/// in the status bar unless something stands out; the numbers live in a popover.
@Observable
final class ResourceMonitor {
    struct ProcessRow: Identifiable, Equatable {
        var id: ProcessIdentity
        var label: String
        /// Nil until the process has been read twice.
        var cpu: Double?
        var memory: UInt64
        /// Runs in the terminal's foreground, which for an agent tab is the agent itself.
        var isForeground: Bool
        var isHot: Bool
    }

    struct Usage: Equatable {
        /// Visible rows only: Ghostty's `login` and the shell wrapper under it are counted, not listed.
        var processes: [ProcessRow] = []
        var cpu: Double = 0
        var memory: UInt64 = 0
    }

    struct Leftover: Identifiable, Equatable {
        var id: UUID
        /// Where the processes came from, for example "feat/auth · Claude Code".
        var origin: String
        var usage: Usage
    }

    enum Alert: Equatable {
        case leftovers(count: Int)
        case memory(name: String, bytes: UInt64)
        case cpu(label: String, percent: Double)
    }

    /// What the app knows about a running terminal, handed over on every scan.
    struct Source {
        var terminal: TerminalSession
        var worktreeID: Worktree.ID
        var worktreeName: String
        var origin: String
    }

    private(set) var sessions: [Session.ID: Usage] = [:]
    private(set) var leftovers: [Leftover] = []
    /// Archipel itself, which includes every Ghostty surface since they render in-process.
    private(set) var app = Usage()
    /// Most pressing first.
    private(set) var alerts: [Alert] = []
    /// Recent memory totals per worktree, oldest first, for the sparklines in the popover.
    private(set) var memoryHistory: [Worktree.ID: [UInt64]] = [:]
    private static let historyLength = 30

    static let memoryWarning: UInt64 = 4 << 30
    static let cpuWarning: Double = 80
    static let cpuWarningDuration: TimeInterval = 120
    /// The processes of a closed tab get SIGHUP and usually exit within a second. Only what is
    /// still around after this is reported.
    private static let leftoverGrace: TimeInterval = 5

    @ObservationIgnored private var tracked: [Session.ID: Tracked] = [:]
    @ObservationIgnored private var closed: [Closed] = []
    @ObservationIgnored private var labels: [ProcessIdentity: String] = [:]
    @ObservationIgnored private var cpuMeter = CPUMeter()
    @ObservationIgnored private var load = SustainedLoad()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isScanning = false
    /// Set by an open popover so its numbers keep up while someone is reading them.
    @ObservationIgnored var isWatched = false
    @ObservationIgnored private var sources: (() -> [Session.ID: Source])?

    private struct Tracked {
        var terminalID: TerminalSession.ID
        var worktreeID: Worktree.ID
        var worktreeName: String
        var origin: String
        var unixSessionID: Int32?
        var members: Set<ProcessIdentity> = []
    }

    private struct Closed {
        var id = UUID()
        var origin: String
        var closedAt: Date
        /// Kept for a short while only: once its last process is gone a session id can be reused.
        var unixSessionID: Int32?
        var members: Set<ProcessIdentity>
    }

    func start(sources: @escaping () -> [Session.ID: Source]) {
        self.sources = sources
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.scan(sources())
                // Slower in the background, but not stopped: a server an agent detaches is only
                // known to belong to the tab if it is seen while its parent is still alive.
                let active = NSApplication.shared.isActive
                try? await Task.sleep(for: self.isWatched ? .seconds(2) : active ? .seconds(4) : .seconds(15))
            }
        }
    }

    /// SIGTERM first; whatever ignores it gets SIGKILL a few seconds later.
    func quit(_ identities: [ProcessIdentity]) {
        guard !identities.isEmpty else { return }
        Task.detached {
            for identity in identities { ProcessSampler.signal(identity, SIGTERM) }
            try? await Task.sleep(for: .seconds(3))
            for identity in identities { ProcessSampler.signal(identity, SIGKILL) }
        }
        // So the rows disappear right away instead of at the next regular scan.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, let sources = self.sources else { return }
            await self.scan(sources())
        }
    }

    // MARK: Scanning

    private func scan(_ sources: [Session.ID: Source]) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let now = Date()

        for (id, entry) in tracked where sources[id]?.terminal.id != entry.terminalID {
            retire(id, at: now)
        }
        for (id, source) in sources {
            if tracked[id] == nil {
                tracked[id] = Tracked(
                    terminalID: source.terminal.id,
                    worktreeID: source.worktreeID,
                    worktreeName: source.worktreeName,
                    origin: source.origin
                )
            }
            tracked[id]?.origin = source.origin
            tracked[id]?.worktreeID = source.worktreeID
            tracked[id]?.worktreeName = source.worktreeName
            if tracked[id]?.unixSessionID == nil, let pid = source.terminal.foregroundProcessID {
                let sid = getsid(pid)
                if sid > 1 { tracked[id]?.unixSessionID = sid }
            }
        }
        closed.removeAll { $0.members.isEmpty && now.timeIntervalSince($0.closedAt) > Self.leftoverGrace }
        for index in closed.indices where now.timeIntervalSince(closed[index].closedAt) > 30 {
            closed[index].unixSessionID = nil
        }

        let sessionOrder = tracked.keys.sorted { $0.uuidString < $1.uuidString }
        let owners: [ProcessAttribution.Owner<OwnerKey>] =
            sessionOrder.map { .init(key: .session($0), unixSessionID: tracked[$0]!.unixSessionID, members: tracked[$0]!.members) }
            + closed.map { .init(key: .closed($0.id), unixSessionID: $0.unixSessionID, members: $0.members) }
        let knownLabels = Set(labels.keys)
        let sample = await Task.detached(priority: .utility) {
            Self.sample(owners: owners, knownLabels: knownLabels)
        }.value

        for (identity, label) in sample.newLabels { labels[identity] = label }
        let percentages = cpuMeter.update(sample.usage.mapValues(\.cpuNanoseconds), at: sample.wallNanoseconds)
        load.update(percentages, threshold: Self.cpuWarning, at: now)
        let hot = load.processes(hotFor: Self.cpuWarningDuration, at: now)
        labels = labels.filter { sample.usage[$0.key] != nil }

        func usage(of identities: Set<ProcessIdentity>, unixSessionID: Int32?, foregroundGroup: Int32?) -> Usage {
            var result = Usage()
            for identity in identities {
                guard let reading = sample.usage[identity], let entry = sample.entries[identity] else { continue }
                let cpu = percentages[identity]
                result.cpu += cpu ?? 0
                result.memory += reading.footprintBytes
                if let sid = unixSessionID, entry.pid == sid || entry.parentPID == sid { continue }
                result.processes.append(ProcessRow(
                    id: identity,
                    label: labels[identity] ?? "pid \(identity.pid)",
                    cpu: cpu,
                    memory: reading.footprintBytes,
                    isForeground: foregroundGroup != nil && entry.processGroupID == foregroundGroup,
                    isHot: hot.contains(identity)
                ))
            }
            result.processes.sort { $0.memory != $1.memory ? $0.memory > $1.memory : $0.id.pid < $1.id.pid }
            return result
        }

        var nextSessions: [Session.ID: Usage] = [:]
        for id in sessionOrder {
            let members = sample.attribution[.session(id)] ?? []
            tracked[id]?.members = members
            let foreground = sources[id]?.terminal.foregroundProcessID
            nextSessions[id] = usage(of: members, unixSessionID: tracked[id]?.unixSessionID, foregroundGroup: foreground)
        }
        var nextLeftovers: [Leftover] = []
        for index in closed.indices {
            let members = sample.attribution[.closed(closed[index].id)] ?? []
            closed[index].members = members
            guard now.timeIntervalSince(closed[index].closedAt) >= Self.leftoverGrace, !members.isEmpty else { continue }
            nextLeftovers.append(Leftover(
                id: closed[index].id,
                origin: closed[index].origin,
                usage: usage(of: members, unixSessionID: nil, foregroundGroup: nil)
            ))
        }
        closed.removeAll { $0.members.isEmpty }

        let ownPID = ProcessIdentity(pid: getpid(), startTime: sample.ownStartTime)
        var nextApp = Usage()
        if let own = sample.usage[ownPID] {
            nextApp.memory = own.footprintBytes
            nextApp.cpu = percentages[ownPID] ?? 0
        }

        var worktreeMemory: [Worktree.ID: (name: String, bytes: UInt64)] = [:]
        for (id, usage) in nextSessions {
            guard let entry = tracked[id] else { continue }
            worktreeMemory[entry.worktreeID, default: (entry.worktreeName, 0)].bytes += usage.memory
        }
        memoryHistory = worktreeMemory.reduce(into: [:]) { result, entry in
            result[entry.key] = ((memoryHistory[entry.key] ?? []) + [entry.value.bytes]).suffix(Self.historyLength)
        }

        let nextAlerts = Self.alerts(sessions: nextSessions, leftovers: nextLeftovers, worktreeMemory: worktreeMemory.values)
        if nextSessions != sessions { sessions = nextSessions }
        if nextLeftovers != leftovers { leftovers = nextLeftovers }
        if nextApp != app { app = nextApp }
        if nextAlerts != alerts { alerts = nextAlerts }
    }

    private func retire(_ id: Session.ID, at now: Date) {
        guard let entry = tracked.removeValue(forKey: id) else { return }
        if !entry.members.isEmpty || entry.unixSessionID != nil {
            closed.append(Closed(origin: entry.origin, closedAt: now,
                                 unixSessionID: entry.unixSessionID, members: entry.members))
        }
    }

    private static func alerts(
        sessions: [Session.ID: Usage],
        leftovers: [Leftover],
        worktreeMemory: some Sequence<(name: String, bytes: UInt64)>
    ) -> [Alert] {
        var alerts: [Alert] = []
        let leftoverCount = leftovers.reduce(0) { $0 + $1.usage.processes.count }
        if leftoverCount > 0 { alerts.append(.leftovers(count: leftoverCount)) }

        for worktree in worktreeMemory.sorted(by: { $0.bytes > $1.bytes }) where worktree.bytes >= memoryWarning {
            alerts.append(.memory(name: worktree.name, bytes: worktree.bytes))
        }

        let hot = sessions.values.flatMap { $0.processes.filter(\.isHot) }
            + leftovers.flatMap { $0.usage.processes.filter(\.isHot) }
        for row in hot.sorted(by: { ($0.cpu ?? 0) > ($1.cpu ?? 0) }) {
            alerts.append(.cpu(label: row.label, percent: row.cpu ?? 0))
        }
        return alerts
    }

    // MARK: Sampling, off the main actor

    nonisolated private enum OwnerKey: Hashable, Sendable {
        case session(Session.ID)
        case closed(UUID)
    }

    nonisolated private struct Sample: Sendable {
        var attribution: [OwnerKey: Set<ProcessIdentity>]
        var entries: [ProcessIdentity: ProcessEntry]
        var usage: [ProcessIdentity: ProcessSampler.Usage]
        var newLabels: [ProcessIdentity: String]
        var wallNanoseconds: UInt64
        var ownStartTime: UInt64
    }

    nonisolated private static func sample(owners: [ProcessAttribution.Owner<OwnerKey>], knownLabels: Set<ProcessIdentity>) -> Sample {
        let ownPID = getpid()
        // Reading the table costs a libproc call per process on the machine. Without owners nothing
        // in it could be attributed, so only our own entry is needed.
        let processes = owners.isEmpty ? [ProcessSampler.process(ownPID)].compactMap(\.self) : ProcessSampler.processes()
        let attribution = ProcessAttribution.attribute(owners, among: processes)
        let own = processes.first { $0.pid == ownPID }
        let attributed = attribution.values.reduce(into: Set<ProcessIdentity>()) { $0.formUnion($1) }
        var entries: [ProcessIdentity: ProcessEntry] = [:]
        var usage: [ProcessIdentity: ProcessSampler.Usage] = [:]
        var newLabels: [ProcessIdentity: String] = [:]
        for process in processes where attributed.contains(process.identity) || process.pid == ownPID {
            guard let reading = ProcessSampler.usage(of: process.pid) else { continue }
            entries[process.identity] = process
            usage[process.identity] = reading
            if !knownLabels.contains(process.identity) {
                let (name, arguments) = ProcessSampler.name(of: process.pid)
                newLabels[process.identity] = ProcessLabel.label(name: name, arguments: arguments)
            }
        }
        return Sample(
            attribution: attribution,
            entries: entries,
            usage: usage,
            newLabels: newLabels,
            wallNanoseconds: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
            ownStartTime: own?.identity.startTime ?? 0
        )
    }
}

#if DEBUG
extension ResourceMonitor {
    /// Readings to show without sampling the process table.
    func showForPreview(
        sessions: [Session.ID: Usage] = [:],
        leftovers: [Leftover] = [],
        app: Usage = Usage(),
        alerts: [Alert] = [],
        memoryHistory: [Worktree.ID: [UInt64]] = [:]
    ) {
        self.sessions = sessions
        self.leftovers = leftovers
        self.app = app
        self.alerts = alerts
        self.memoryHistory = memoryHistory
    }
}
#endif
