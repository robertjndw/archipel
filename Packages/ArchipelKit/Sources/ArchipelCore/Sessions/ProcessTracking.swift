import Foundation

/// Pids are recycled, so a pid alone can name a different process a minute later. Together with
/// the start time it names exactly one.
public struct ProcessIdentity: Hashable, Sendable {
    public var pid: Int32
    /// Microseconds since 1970.
    public var startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }
}

/// One row of the process table, with just what attribution needs.
public struct ProcessEntry: Equatable, Sendable {
    public var identity: ProcessIdentity
    public var parentPID: Int32
    /// The Unix session (`getsid`), not an Archipel session.
    public var unixSessionID: Int32
    public var processGroupID: Int32

    public var pid: Int32 { identity.pid }

    public init(identity: ProcessIdentity, parentPID: Int32, unixSessionID: Int32, processGroupID: Int32 = 0) {
        self.identity = identity
        self.parentPID = parentPID
        self.unixSessionID = unixSessionID
        self.processGroupID = processGroupID
    }
}

/// Decides which processes belong to which terminal.
///
/// Ghostty starts every terminal in a Unix session of its own, so anything sharing that session id
/// is the terminal's. That misses processes that detach into a session of their own (Node's
/// `detached: true`, `setsid`), which is how agents usually start background servers. Those are
/// still caught as descendants, and once seen they stay members for as long as they live: when
/// their parent exits they are reparented to launchd and the tree no longer leads to them.
public enum ProcessAttribution {
    public struct Owner<Key: Hashable>: Sendable where Key: Sendable {
        public var key: Key
        public var unixSessionID: Int32?
        public var members: Set<ProcessIdentity>

        public init(key: Key, unixSessionID: Int32?, members: Set<ProcessIdentity>) {
            self.key = key
            self.unixSessionID = unixSessionID
            self.members = members
        }
    }

    /// Owners earlier in the list win a process that two of them could claim.
    public static func attribute<Key>(_ owners: [Owner<Key>], among processes: [ProcessEntry]) -> [Key: Set<ProcessIdentity>] {
        var children: [Int32: [ProcessEntry]] = [:]
        var alive: Set<ProcessIdentity> = []
        for process in processes {
            children[process.parentPID, default: []].append(process)
            alive.insert(process.identity)
        }
        var claimed: Set<Int32> = []
        var result: [Key: Set<ProcessIdentity>] = [:]

        for owner in owners {
            var queue: [ProcessEntry] = []
            // Session ids 0 and 1 would sweep in the kernel and launchd's whole session.
            if let sid = owner.unixSessionID, sid > 1 {
                queue += processes.filter { $0.unixSessionID == sid }
            }
            if !owner.members.isEmpty {
                queue += processes.filter { owner.members.contains($0.identity) }
            }
            var found: Set<ProcessIdentity> = []
            while let process = queue.popLast() {
                guard process.pid > 1, !claimed.contains(process.pid) else { continue }
                claimed.insert(process.pid)
                found.insert(process.identity)
                queue += children[process.pid] ?? []
            }
            result[owner.key] = found
        }
        return result
    }
}

/// CPU percentage from two readings of a process's cumulative CPU time. 100 means one full core.
public struct CPUMeter: Sendable {
    private var previous: [ProcessIdentity: Reading] = [:]

    private struct Reading: Sendable {
        var cpuNanoseconds: UInt64
        var wallNanoseconds: UInt64
    }

    public init() {}

    /// Readings of processes that are not passed in are dropped. A process seen for the first time
    /// has no percentage yet.
    public mutating func update(_ cpuNanoseconds: [ProcessIdentity: UInt64], at wallNanoseconds: UInt64) -> [ProcessIdentity: Double] {
        var percentages: [ProcessIdentity: Double] = [:]
        var next: [ProcessIdentity: Reading] = [:]
        for (identity, cpu) in cpuNanoseconds {
            if let last = previous[identity], wallNanoseconds > last.wallNanoseconds, cpu >= last.cpuNanoseconds {
                percentages[identity] = Double(cpu - last.cpuNanoseconds) / Double(wallNanoseconds - last.wallNanoseconds) * 100
            }
            next[identity] = Reading(cpuNanoseconds: cpu, wallNanoseconds: wallNanoseconds)
        }
        previous = next
        return percentages
    }
}

/// Remembers since when each process has been above a CPU threshold, so a build that spikes for a
/// few seconds does not raise a warning while a watcher spinning for minutes does.
public struct SustainedLoad: Sendable {
    private var hotSince: [ProcessIdentity: Date] = [:]

    public init() {}

    public mutating func update(_ percentages: [ProcessIdentity: Double], threshold: Double, at now: Date) {
        var next: [ProcessIdentity: Date] = [:]
        for (identity, percent) in percentages where percent >= threshold {
            next[identity] = hotSince[identity] ?? now
        }
        hotSince = next
    }

    public func processes(hotFor duration: TimeInterval, at now: Date) -> Set<ProcessIdentity> {
        Set(hotSince.filter { now.timeIntervalSince($0.value) >= duration }.keys)
    }
}

/// A name a person recognizes. The kernel's name for a dev server is usually just "node".
public enum ProcessLabel {
    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl", "php"]
    private static let packageManagers: Set<String> = ["npm", "npx", "pnpm", "pnpx", "yarn", "bun", "bunx", "uv", "pip"]
    /// What package managers' entry scripts are called on disk.
    private static let scriptAliases = ["npm-cli": "npm", "npx-cli": "npx", "yarn": "yarn", "pnpm": "pnpm"]

    public static func label(name: String, arguments: [String]) -> String {
        let executable = arguments.first.map(baseName) ?? name
        let tool = interpreters.contains(executable) || executable.hasPrefix("python3.")
            ? script(in: arguments.dropFirst()) ?? executable
            : executable
        guard !tool.isEmpty else { return name }
        if packageManagers.contains(tool), let start = arguments.firstIndex(where: { scriptName($0) == tool || baseName($0) == tool }) {
            // "npm run dev" says far more than "npm".
            let rest = arguments[(start + 1)...].prefix { !$0.hasPrefix("-") }.prefix(2)
            return ([tool] + rest).joined(separator: " ")
        }
        return tool
    }

    private static func script(in arguments: ArraySlice<String>) -> String? {
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            if argument == "-m" { return iterator.next() }
            if argument == "-c" || argument == "-e" || argument == "--eval" { return nil }
            if argument.hasPrefix("-") { continue }
            return scriptName(argument)
        }
        return nil
    }

    private static func scriptName(_ path: String) -> String {
        var name = baseName(path)
        for suffix in [".js", ".mjs", ".cjs", ".ts", ".py", ".rb"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        // `node_modules/vite/bin/vite.js` is vite; `node_modules/.bin/vite` already says so.
        if name == "cli" || name == "index" || name == "bin" {
            let parts = path.split(separator: "/").map(String.init)
            if let package = parts.dropLast().last(where: { $0 != "bin" && $0 != "dist" && $0 != "lib" && !$0.hasPrefix(".") }) {
                return package
            }
        }
        return scriptAliases[name] ?? name
    }

    private static func baseName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}
