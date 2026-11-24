import AppKit
import ArchipelCore
import Darwin
import Foundation
import Observation
import TerminalKit

/// Finds local dev servers that sessions announce in their output, for the
/// link pill on their tabs.
///
/// Ghostty has no output callback, so this polls each live terminal's
/// viewport every couple of seconds and only scans text that changed. Every
/// session is polled, not just visible ones, because tabs in the background
/// show pills too and a banner can scroll away before the tab is selected.
/// A URL only becomes a pill once something accepts connections on its port,
/// which keeps URLs that are merely mentioned (docs, an agent's reply) out. A port whose listener
/// belongs to another tab's processes is that tab's, so a tab that only mentions another tab's
/// server gets no pill; see `DevServerAttribution` for why owning the listener is not required.
@Observable
final class DevServerMonitor {
    /// Confirmed servers per session, oldest first.
    private(set) var links: [Session.ID: [DevServerLink]] = [:]

    @ObservationIgnored private var states: [Session.ID: ScanState] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var isScanning = false
    @ObservationIgnored private var tick = 0
    /// When the app last came back to the front, after which the process scan needs a while to catch up.
    @ObservationIgnored private var resumedAt: ContinuousClock.Instant?

    private struct ScanState {
        /// A restarted session gets a new terminal, and its old servers must not carry over.
        var terminalID: TerminalSession.ID
        var textHash: Int?
        /// Seen in the output but not yet accepting connections, with the probes left before giving up.
        var candidates: [DevServerLink] = []
        var candidateProbesLeft: [Int: Int] = [:]
        /// When each candidate port was first found open, to know when its owner should be known.
        var openSince: [Int: ContinuousClock.Instant] = [:]
        /// Consecutive failed probes per confirmed port; one alone is not trusted.
        var misses: [Int: Int] = [:]
    }

    private static let interval: Duration = .seconds(2)
    /// Servers often print their URL a moment before they bind, or the first
    /// probe lands while they restart.
    private static let candidateProbes = 5
    private static let missesBeforeRemoval = 2

    /// `processIDs` says which processes belong to each session, to tell whose listener a port is.
    func start(
        terminals: @escaping () -> [Session.ID: TerminalSession],
        processIDs: @escaping () -> [Session.ID: [Int32]] = { [:] }
    ) {
        task?.cancel()
        task = Task { [weak self] in
            var resumed = false
            while !Task.isCancelled {
                // Nobody sees a pill while the app is in the background, so the probes are not
                // worth the wakeups. Servers started or stopped meanwhile are caught on return,
                // with confirmed pills rechecked too instead of waiting for their slower cadence.
                if !(await MainActor.run { NSApplication.shared.isActive }) {
                    for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) { break }
                    resumed = true
                    self?.resumedAt = .now
                } else if !resumed {
                    try? await Task.sleep(for: Self.interval)
                }
                guard !Task.isCancelled, let self else { return }
                await self.scan(terminals(), processIDs: processIDs(), recheckConfirmed: resumed)
                resumed = false
            }
        }
    }

    private func scan(_ terminals: [Session.ID: TerminalSession], processIDs: [Session.ID: [Int32]], recheckConfirmed: Bool = false) async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        tick += 1

        for id in Set(states.keys).union(links.keys) {
            let terminal = terminals[id]
            if terminal == nil || terminal?.hasExited == true || states[id]?.terminalID != terminal?.id {
                forget(id)
            }
        }

        var probes: [Session.ID: [DevServerLink]] = [:]
        for (id, terminal) in terminals where !terminal.hasExited {
            var state = states[id] ?? ScanState(terminalID: terminal.id)
            let text = terminal.readVisibleText()
            let hash = text.hashValue
            if hash != state.textHash {
                state.textHash = hash
                let known = Set((links[id] ?? []).map(\.port))
                let fresh = DevServerDetector.links(in: text).filter { !known.contains($0.port) }
                for link in fresh where state.candidateProbesLeft[link.port] == nil {
                    state.candidateProbesLeft[link.port] = Self.candidateProbes
                }
                state.candidates = DevServerDetector.merge(known: state.candidates, detected: fresh)
            }
            states[id] = state
            // Confirmed servers are checked at half the rate; a pill that lingers
            // a few seconds after its server stops is harmless.
            let confirmed = recheckConfirmed || tick.isMultiple(of: 2) ? links[id] ?? [] : []
            if !state.candidates.isEmpty || !confirmed.isEmpty {
                probes[id] = confirmed + state.candidates
            }
        }
        guard !probes.isEmpty else { return }

        let listening = await Self.listeningPorts(probes)
        // Only open candidates need an owner; confirmed servers were vetted when they appeared.
        let hasOpenCandidate = probes.keys.contains { id in
            let open = listening[id] ?? []
            return states[id]?.candidates.contains { open.contains($0.port) } == true
        }
        let listeners = hasOpenCandidate ? await Self.listenerPorts(of: processIDs) : [:]
        let now = ContinuousClock.now

        for (id, probed) in probes {
            // The session may have closed or restarted while the probes ran.
            guard let terminal = terminals[id], !terminal.hasExited, var state = states[id],
                  state.terminalID == terminal.id
            else { continue }
            let open = listening[id] ?? []
            var current = links[id] ?? []
            for link in probed where current.contains(where: { $0.port == link.port }) {
                if open.contains(link.port) {
                    state.misses[link.port] = nil
                } else {
                    let misses = (state.misses[link.port] ?? 0) + 1
                    state.misses[link.port] = misses
                    if misses >= Self.missesBeforeRemoval {
                        current.removeAll { $0.port == link.port }
                        state.misses[link.port] = nil
                    }
                }
            }
            for link in state.candidates {
                guard open.contains(link.port) else {
                    state.openSince[link.port] = nil
                    state.candidateProbesLeft[link.port, default: 1] -= 1
                    continue
                }
                let since = state.openSince[link.port] ?? now
                state.openSince[link.port] = since
                let settled = DevServerAttribution.isSettled(openSince: since, resumedAt: resumedAt, now: now)
                switch DevServerAttribution.verdict(for: id, port: link.port, listeners: listeners, isSettled: settled) {
                case .accept:
                    current = DevServerDetector.merge(known: current, detected: [link])
                    state.candidateProbesLeft[link.port] = nil
                case .veto:
                    // Spent rather than dropped at once: the owner's server may be the one that
                    // just stopped, with this session's taking the port before the next process scan.
                    state.candidateProbesLeft[link.port, default: 1] -= 1
                case .wait:
                    // Waiting on the process scan is not the server failing to answer, so a slow
                    // scan cannot run out a real server's probes.
                    break
                }
            }
            // Drop the counter along with the candidate: a leftover zero would stop the same
            // port from ever being re-armed when a slow server finally binds and is seen again.
            for link in state.candidates where (state.candidateProbesLeft[link.port] ?? 0) <= 0 {
                state.candidateProbesLeft[link.port] = nil
            }
            state.candidates.removeAll { state.candidateProbesLeft[$0.port] == nil }
            state.openSince = state.openSince.filter { port, _ in state.candidates.contains { $0.port == port } }
            states[id] = state
            if current != (links[id] ?? []) {
                links[id] = current.isEmpty ? nil : current
            }
        }
    }

    private func forget(_ id: Session.ID) {
        states[id] = nil
        if links[id] != nil { links[id] = nil }
    }

    // MARK: Probing

    /// Ports that accepted a TCP connection, per session. Off the main actor:
    /// a connect to a port nobody answers can take until the timeout.
    nonisolated private static func listeningPorts(_ probes: [Session.ID: [DevServerLink]]) async -> [Session.ID: Set<Int>] {
        await withTaskGroup(of: (Session.ID, Int, Bool).self) { group in
            for (id, links) in probes {
                for link in links {
                    group.addTask {
                        (id, link.port, link.probeAddresses.contains { canConnect(to: $0, port: link.port) })
                    }
                }
            }
            var result: [Session.ID: Set<Int>] = [:]
            for await (id, port, isOpen) in group where isOpen {
                result[id, default: []].insert(port)
            }
            return result
        }
    }

    /// The ports each session's processes listen on.
    nonisolated private static func listenerPorts(of sessions: [Session.ID: [Int32]]) async -> [Session.ID: Set<Int>] {
        await Task.detached(priority: .utility) {
            var result: [Session.ID: Set<Int>] = [:]
            for (id, pids) in sessions {
                result[id] = pids.reduce(into: Set<Int>()) { $0.formUnion(ProcessSampler.listeningPorts(of: $1)) }
            }
            return result
        }.value
    }

    nonisolated private static func canConnect(to address: String, port: Int) -> Bool {
        let isIPv6 = address.contains(":")
        let fd = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let result: Int32
        if isIPv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET6, address, &addr.sin6_addr) == 1 else { return false }
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET, address, &addr.sin_addr) == 1 else { return false }
            result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pollDescriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pollDescriptor, 1, 300) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}

#if DEBUG
extension DevServerMonitor {
    /// Pills to show without scanning any terminal.
    func showForPreview(_ links: [Session.ID: [DevServerLink]]) {
        self.links = links
    }
}
#endif
