import ArchipelCore
import Darwin
import Foundation

/// Reads the process table through libproc. Only the user's own processes are visible without
/// privileges, which is all Archipel can have started anyway.
nonisolated enum ProcessSampler {
    struct Usage: Sendable {
        var cpuNanoseconds: UInt64
        /// `phys_footprint`, the figure Activity Monitor calls Memory. Resident size counts shared
        /// pages once per process and makes a few Node workers look several times their real size.
        var footprintBytes: UInt64
    }

    /// Every process of the current user.
    static func processes() -> [ProcessEntry] {
        let uid = getuid()
        return allPIDs().compactMap { pid in
            guard let info = bsdInfo(pid), info.pbi_uid == uid else { return nil }
            return ProcessEntry(
                identity: identity(pid, info),
                parentPID: Int32(info.pbi_ppid),
                unixSessionID: getsid(pid),
                processGroupID: Int32(info.pbi_pgid)
            )
        }
    }

    static func usage(of pid: Int32) -> Usage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // rusage times are in mach ticks, which are not nanoseconds on Apple silicon.
        let ticks = info.ri_user_time + info.ri_system_time
        return Usage(cpuNanoseconds: ticks * UInt64(timebase.numer) / UInt64(timebase.denom), footprintBytes: info.ri_phys_footprint)
    }

    /// The short name and the arguments, for a label.
    static func name(of pid: Int32) -> (name: String, arguments: [String]) {
        var buffer = [CChar](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        let name = proc_name(pid, &buffer, UInt32(buffer.count)) > 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            : ""
        return (name, arguments(of: pid))
    }

    /// Whether `identity` still names a running process, so a pid that was recycled is never signalled.
    static func isAlive(_ identity: ProcessIdentity) -> Bool {
        guard let info = bsdInfo(identity.pid) else { return false }
        return self.identity(identity.pid, info) == identity
    }

    static func signal(_ identity: ProcessIdentity, _ signal: Int32) {
        guard identity.pid > 1, identity.pid != getpid(), isAlive(identity) else { return }
        kill(identity.pid, signal)
    }

    // MARK: libproc

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func allPIDs() -> [Int32] {
        // Sized from a first call with headroom, since processes start between the two calls.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 128)
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        return count > 0 ? Array(pids.prefix(Int(count))).filter { $0 > 0 } : []
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    private static func identity(_ pid: Int32, _ info: proc_bsdinfo) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startTime: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }

    /// KERN_PROCARGS2 is argc, the executable path, padding, then argv, all NUL separated. The
    /// environment that used to follow is withheld for other processes.
    private static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}
