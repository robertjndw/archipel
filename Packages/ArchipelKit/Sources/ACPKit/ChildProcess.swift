import Darwin
import Foundation
import Synchronization

/// How a child process ended.
public enum ChildProcessTermination: Sendable, Hashable, CustomStringConvertible {
    case exited(Int32)
    case signaled(Int32)

    public var description: String {
        switch self {
        case let .exited(code): "exited with status \(code)"
        case let .signaled(signal): "terminated by signal \(signal)"
        }
    }
}

public enum ChildProcessError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    case executableNotFound(String)
    case notExecutable(String)
    case spawnFailed(path: String, errno: Int32)
    case system(call: String, errno: Int32)
    /// The child no longer reads its input, usually because it exited.
    case brokenPipe
    /// `closeInput()` was called before this write.
    case inputClosed
    case writeFailed(errno: Int32)

    public var description: String {
        switch self {
        case let .executableNotFound(path): "No executable found at \(path)"
        case let .notExecutable(path): "\(path) is not executable"
        case let .spawnFailed(path, code): "Could not start \(path): \(String(cString: strerror(code)))"
        case let .system(call, code): "\(call) failed: \(String(cString: strerror(code)))"
        case .brokenPipe: "The process stopped reading its input"
        case .inputClosed: "The process input was already closed"
        case let .writeFailed(code): "Writing to the process failed: \(String(cString: strerror(code)))"
        }
    }

    public var errorDescription: String? { description }
}

/// A child process with piped stdin, stdout and stderr, leading its own process group.
///
/// Hand-rolled on `posix_spawn` because `Foundation.Process` cannot start the child in a new
/// session. Agents are often launched through wrappers (npx starts node, which starts the
/// native agent), and only signalling the whole group reliably stops all of them.
///
/// Writes report a closed pipe as `ChildProcessError.brokenPipe`; the pipe is also marked so it
/// never raises SIGPIPE. The host app should still ignore SIGPIPE, as any app that writes to
/// pipes or sockets must.
public final class ChildProcess: Sendable {
    /// The child's pid, which is also its process group id and session id.
    public let pid: pid_t
    public var processGroup: pid_t { pid }

    /// The child's stdout in chunks as they arrive. Finishes once both stdout and stderr reached
    /// end of file, so `stderrText` is complete by then, or shortly after the child exited if
    /// something it left behind still holds a pipe open.
    public let output: AsyncStream<Data>

    /// How much of stderr is kept for failure messages.
    public static let stderrCapacity = 64 * 1024

    /// How long output may keep flowing after the child exited before reading stops.
    static let drainAfterExit: DispatchTimeInterval = .milliseconds(500)

    // Writes and the close of stdin run on one serial queue. Closing on another thread while a
    // write is blocked could free the descriptor number for reuse and send the rest of the
    // write into an unrelated file.
    private let writeQueue = DispatchQueue(label: "archipel.acp.child.stdin")
    private let readQueue = DispatchQueue(label: "archipel.acp.child.output")
    private let stdinDescriptor: Mutex<Int32>
    private let stdoutReader: PipeReader
    private let stderrReader: PipeReader
    private let stderrBuffer = SharedRing(capacity: ChildProcess.stderrCapacity)
    private let exitState = Mutex(ExitState())
    /// Guards every signal to the group, and the reaping of the child, so that what the state
    /// says about the group id is still true when the signal goes out.
    private let group = Mutex(GroupState())

    private struct ExitState {
        var termination: ChildProcessTermination?
        var waiters: [Int: CheckedContinuation<ChildProcessTermination?, Never>] = [:]
        var nextWaiter = 0
    }

    /// What is known about the process group, whose id is the child's pid.
    private enum GroupLife {
        /// The child is not reaped yet, so its pid, and with it the group id, is still ours.
        case leaderUnreaped
        /// The child is reaped, but the last probe found a member of the group still there.
        case membersLeft
        /// No member is left. The id may belong to an unrelated group by now.
        case gone
    }

    private struct GroupState {
        var life = GroupLife.leaderUnreaped
        /// Signals actually sent, for tests.
        var sent: [Int32] = []
    }

    /// Starts `executable` with `arguments`. A bare name is looked up in `environment["PATH"]`.
    public init(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectory: String? = nil
    ) throws {
        let path = try Self.resolve(executable, path: environment["PATH"])
        let stdin = try Self.makePipe()
        let stdout: (read: Int32, write: Int32)
        let stderr: (read: Int32, write: Int32)
        do {
            stdout = try Self.makePipe()
            do {
                stderr = try Self.makePipe()
            } catch {
                Self.close(stdout)
                throw error
            }
        } catch {
            Self.close(stdin)
            throw error
        }
        let childEnds = [stdin.read, stdout.write, stderr.write]
        let parentEnds = [stdin.write, stdout.read, stderr.read]

        let spawned: pid_t
        do {
            spawned = try Self.spawn(
                path: path,
                arguments: arguments,
                environment: environment,
                currentDirectory: currentDirectory,
                stdin: stdin.read,
                stdout: stdout.write,
                stderr: stderr.write
            )
        } catch {
            (childEnds + parentEnds).forEach { Darwin.close($0) }
            throw error
        }
        childEnds.forEach { Darwin.close($0) }

        pid = spawned
        _ = fcntl(stdin.write, F_SETNOSIGPIPE, 1)
        _ = fcntl(stdout.read, F_SETFL, fcntl(stdout.read, F_GETFL) | O_NONBLOCK)
        _ = fcntl(stderr.read, F_SETFL, fcntl(stderr.read, F_GETFL) | O_NONBLOCK)
        stdinDescriptor = Mutex(stdin.write)

        let (output, continuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        self.output = output
        let openPipes = Countdown(2)
        let pipeEnded: @Sendable () -> Void = {
            if openPipes.countDown() { continuation.finish() }
        }
        stdoutReader = PipeReader(fd: stdout.read, queue: readQueue, onChunk: { continuation.yield($0) }, onEnd: pipeEnded)
        let buffer = stderrBuffer
        stderrReader = PipeReader(fd: stderr.read, queue: readQueue, onChunk: { buffer.append($0) }, onEnd: pipeEnded)
        stdoutReader.start()
        stderrReader.start()

        // A blocking waitpid on a thread of its own: it reaps the child, so no zombie is left,
        // and unlike a kqueue exit source it cannot miss a child that exited before it was set up.
        let thread = Thread { [self] in reap() }
        thread.name = "archipel.acp.child.wait"
        thread.start()
    }

    // MARK: Output and exit

    /// The last `stderrCapacity` bytes of stderr, decoded leniently.
    public var stderrText: String {
        String(decoding: stderrBuffer.contents, as: UTF8.self)
    }

    /// How the child ended, or nil while it runs.
    public var termination: ChildProcessTermination? {
        exitState.withLock { $0.termination }
    }

    /// Waits for the child to exit. Throws `CancellationError` if the waiting task is cancelled.
    public func waitForExit() async throws -> ChildProcessTermination {
        guard let termination = await exitOrCancellation() else { throw CancellationError() }
        return termination
    }

    /// Waits for the child to exit, or for `timeout` to pass, whichever comes first.
    public func waitForExit(timeout: Duration) async -> ChildProcessTermination? {
        if let termination { return termination }
        return await withTaskGroup(of: ChildProcessTermination?.self) { group in
            group.addTask { await self.exitOrCancellation() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? termination
        }
    }

    private func exitOrCancellation() async -> ChildProcessTermination? {
        let id = exitState.withLock { state in
            defer { state.nextWaiter += 1 }
            return state.nextWaiter
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let immediate: ChildProcessTermination?? = exitState.withLock { state in
                    if let termination = state.termination { return .some(termination) }
                    if Task.isCancelled { return .some(nil) }
                    state.waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(returning: immediate) }
            }
        } onCancel: {
            exitState.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: nil)
        }
    }

    private func reap() {
        // Waits without reaping, so the pid stays taken until the lock below is held: reaping is
        // what frees the group id, and the group state has to change in the same step.
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) < 0, errno == EINTR {}
        var status: Int32 = 0
        group.withLock { group in
            while waitpid(pid, &status, 0) < 0 {
                // ECHILD would mean someone else reaped it; nothing more can be learned then.
                guard errno == EINTR else { break }
            }
            group.life = Self.probe(processGroup) ? .membersLeft : .gone
        }
        // The <sys/wait.h> macros do not come through to Swift.
        let signal = status & 0x7F
        let termination: ChildProcessTermination = signal == 0 ? .exited((status >> 8) & 0xFF) : .signaled(signal)
        let waiters = exitState.withLock { state in
            state.termination = termination
            defer { state.waiters = [:] }
            return state.waiters.values
        }
        waiters.forEach { $0.resume(returning: termination) }

        // A grandchild that inherited stdout keeps it open after the child is gone, and end of
        // file would never come. Take what is there and stop.
        let stdoutReader = stdoutReader
        let stderrReader = stderrReader
        readQueue.asyncAfter(deadline: .now() + Self.drainAfterExit) {
            stdoutReader.stop()
            stderrReader.stop()
        }
    }

    // MARK: Input

    /// Writes all of `data` to the child's stdin.
    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writeQueue.async {
                continuation.resume(with: Result { try self.writeAll(data) })
            }
        }
    }

    private func writeAll(_ data: Data) throws {
        let fd = stdinDescriptor.withLock { $0 }
        guard fd >= 0 else { throw ChildProcessError.inputClosed }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, base + offset, buffer.count - offset)
                if written >= 0 {
                    offset += written
                } else if errno == EINTR {
                    continue
                } else if errno == EPIPE {
                    throw ChildProcessError.brokenPipe
                } else {
                    throw ChildProcessError.writeFailed(errno: errno)
                }
            }
        }
    }

    /// Closes the child's stdin after any writes already queued, which tells a well-behaved child to exit.
    public func closeInput() {
        writeQueue.async {
            let fd = self.stdinDescriptor.withLock { fd in
                defer { fd = -1 }
                return fd
            }
            if fd >= 0 { Darwin.close(fd) }
        }
    }

    // MARK: Stopping

    /// Sends `signal` to the child's whole process group, or does nothing once the group is gone.
    ///
    /// A group id is only free for reuse once no process has it as its pid or its group, so
    /// signalling is safe while the child is unreaped (its pid holds the id), and after that only
    /// while some member is known to be alive. Once a probe finds the group empty it is marked gone
    /// for good and never signalled again: from then on the id may name an unrelated group. After
    /// the child is reaped each signal is preceded by a fresh probe, under the same lock; the last
    /// member could still exit between the probe and the signal, but the id would then have to be
    /// handed out again within those microseconds for a stranger to be hit.
    public func signalGroup(_ signal: Int32) {
        group.withLock { group in
            switch group.life {
            case .gone:
                return
            case .membersLeft:
                guard Self.probe(processGroup) else {
                    group.life = .gone
                    return
                }
            case .leaderUnreaped:
                break
            }
            if kill(-processGroup, signal) == 0 { group.sent.append(signal) }
        }
    }

    /// Signals sent to the group so far, for tests.
    var sentSignals: [Int32] {
        group.withLock { $0.sent }
    }

    /// Whether the group is known to be empty, after which nothing is signalled any more.
    var isGroupGone: Bool {
        group.withLock { $0.life == .gone }
    }

    /// Whether any process is in `group`. EPERM means one is, owned by someone else, which can only
    /// be a member that changed its credentials.
    private static func probe(_ group: pid_t) -> Bool {
        kill(-group, 0) == 0 || errno == EPERM
    }

    /// Stops the child and everything it started: closes stdin, gives it `gracePeriod` to exit,
    /// then SIGTERMs the group, waits `terminateTimeout`, and SIGKILLs the group. Processes left
    /// in the group after the child exited are stopped the same way. Returns nil only if the
    /// child survived SIGKILL for several seconds. Cancelling the calling task skips the waits.
    ///
    /// The default grace is generous because agents take their time: Codex needed up to 4.2 s
    /// to exit after its input closed, and a SIGTERM before that cuts off its own cleanup.
    @discardableResult
    public func shutdown(gracePeriod: Duration = .seconds(5), terminateTimeout: Duration = .seconds(2)) async -> ChildProcessTermination? {
        closeInput()
        var result = await waitForExit(timeout: gracePeriod)
        if result == nil {
            signalGroup(SIGTERM)
            result = await waitForExit(timeout: terminateTimeout)
        }
        if result == nil {
            signalGroup(SIGKILL)
            result = await waitForExit(timeout: .seconds(5))
        }
        await stopLeftovers(timeout: terminateTimeout)
        return result
    }

    /// Best effort for when there is no time to wait, such as app termination: closes stdin
    /// and SIGTERMs the group, then returns at once.
    public func terminateNow() {
        closeInput()
        signalGroup(SIGTERM)
    }

    /// Probes the group again and records it gone when it is empty.
    private var groupIsAlive: Bool {
        group.withLock { group in
            switch group.life {
            case .gone:
                return false
            case .leaderUnreaped:
                return true
            case .membersLeft:
                if Self.probe(processGroup) { return true }
                group.life = .gone
                return false
            }
        }
    }

    private func stopLeftovers(timeout: Duration) async {
        guard groupIsAlive else { return }
        signalGroup(SIGTERM)
        // Nothing to wait on for processes that are not our children, so poll, briefly.
        let deadline = ContinuousClock.now + timeout
        while groupIsAlive, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if groupIsAlive { signalGroup(SIGKILL) }
    }

    // MARK: Spawning

    private static func resolve(_ executable: String, path: String?) throws -> String {
        let fileManager = FileManager.default
        guard !executable.contains("/") else {
            guard fileManager.fileExists(atPath: executable) else { throw ChildProcessError.executableNotFound(executable) }
            guard fileManager.isExecutableFile(atPath: executable) else { throw ChildProcessError.notExecutable(executable) }
            return executable
        }
        let directories = (path ?? "").split(separator: ":").map(String.init)
        for directory in directories {
            let candidate = (directory as NSString).appendingPathComponent(executable)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate)
            {
                return candidate
            }
        }
        throw ChildProcessError.executableNotFound(executable)
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ChildProcessError.system(call: "pipe", errno: errno) }
        // Our ends must not leak into processes other threads spawn, or this child's stdout would
        // stay open as long as they live. macOS has no pipe2, so there is a tiny window here;
        // Foundation's own spawns use POSIX_SPAWN_CLOEXEC_DEFAULT, which closes it for them.
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        return (fds[0], fds[1])
    }

    private static func close(_ pipe: (read: Int32, write: Int32)) {
        Darwin.close(pipe.read)
        Darwin.close(pipe.write)
    }

    private static func spawn(
        path: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: String?,
        stdin: Int32,
        stdout: Int32,
        stderr: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
        if let currentDirectory {
            let result = posix_spawn_file_actions_addchdir(&actions, currentDirectory)
            guard result == 0 else { throw ChildProcessError.system(call: "posix_spawn_file_actions_addchdir", errno: result) }
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // SETSID: the child leads a new session and process group, so the group can be signalled.
        // CLOEXEC_DEFAULT: only the three descriptors above reach the child, nothing else the app has open.
        // SETSIGDEF and SETSIGMASK: the host ignores SIGPIPE and that would be inherited across exec,
        // leaving the agent unable to die of a closed pipe the normal way.
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)

        let argv = ([path] + arguments).map { strdup($0) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, path, &actions, &attributes, argv + [nil], envp + [nil])
        guard result == 0 else {
            if result == ENOENT { throw ChildProcessError.executableNotFound(path) }
            throw ChildProcessError.spawnFailed(path: path, errno: result)
        }
        return pid
    }
}

/// Reads one pipe on a serial queue until end of file or until stopped.
private final class PipeReader: Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let source: any DispatchSourceRead
    private let onChunk: @Sendable (Data) -> Void
    /// Set once the source is cancelled. Its cancel handler closes the descriptor, after which the
    /// number may belong to another file, so nothing may read from it again.
    private let isStopped = Mutex(false)

    init(fd: Int32, queue: DispatchQueue, onChunk: @escaping @Sendable (Data) -> Void, onEnd: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.queue = queue
        self.onChunk = onChunk
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler {
            Darwin.close(fd)
            onEnd()
        }
    }

    func start() {
        source.setEventHandler { [self] in readAvailable() }
        source.resume()
    }

    /// Reads what is buffered in the pipe, then stops. Call on the reader's queue.
    func stop() {
        readAvailable()
        cancel()
    }

    private func readAvailable() {
        // Bounded, so a child that writes nonstop cannot keep the queue to itself; the source fires again.
        for _ in 0..<16 {
            guard !isStopped.withLock({ $0 }) else { return }
            var chunk = Data(count: 64 * 1024)
            let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                chunk.count = count
                onChunk(chunk)
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN {
                return
            } else {
                return cancel()
            }
        }
    }

    private func cancel() {
        let wasStopped = isStopped.withLock { stopped in
            defer { stopped = true }
            return stopped
        }
        if !wasStopped { source.cancel() }
    }
}

/// Counts down to zero once, from any thread.
final class Countdown: Sendable {
    private let remaining: Mutex<Int>

    init(_ count: Int) {
        remaining = Mutex(count)
    }

    /// Returns true for the call that reaches zero.
    func countDown() -> Bool {
        remaining.withLock { remaining in
            remaining -= 1
            return remaining == 0
        }
    }
}

/// A ring shared between the reader that fills it and whoever asks for the text.
final class SharedRing: Sendable {
    private let ring: Mutex<ByteRing>

    init(capacity: Int) {
        ring = Mutex(ByteRing(capacity: capacity))
    }

    var contents: Data { ring.withLock { $0.contents } }

    func append(_ bytes: Data) {
        ring.withLock { $0.append(bytes) }
    }
}

/// Keeps the most recent bytes up to a capacity.
struct ByteRing: Sendable {
    let capacity: Int
    private var storage = Data()

    init(capacity: Int) {
        self.capacity = capacity
    }

    var contents: Data {
        storage.count > capacity ? Data(storage.suffix(capacity)) : storage
    }

    mutating func append(_ bytes: Data) {
        storage.append(bytes)
        // Trimmed only at twice the capacity, so a chatty stderr costs a copy now and then, not per chunk.
        if storage.count > capacity * 2 {
            storage = Data(storage.suffix(capacity))
        }
    }
}
