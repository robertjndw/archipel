@testable import ACPKit
import Darwin
import Foundation
import Testing

/// A minimal ACP agent in Perl, which macOS ships with JSON::PP. Logs to stderr, answers
/// initialize, session/new and session/prompt (echoing the prompt text back as a chunk), exits
/// with 7 when asked to via a prompt of "die", and with 3 at end of input.
private let fakeAgentScript = #"""
use strict;
use warnings;
use JSON::PP;

$| = 1;
my $json = JSON::PP->new->utf8->canonical;
print STDERR "fake agent: started\n";

sub send_message { print $json->encode($_[0]), "\n"; }
sub reply { send_message({ jsonrpc => "2.0", id => $_[0], result => $_[1] }); }

while (my $line = <STDIN>) {
    chomp $line;
    next unless length $line;
    my $message = $json->decode($line);
    my $method = $message->{method} // "";
    my $id = $message->{id};
    if ($method eq "initialize") {
        reply($id, { protocolVersion => 1, agentCapabilities => { loadSession => JSON::PP::true }, authMethods => [] });
    } elsif ($method eq "session/new") {
        reply($id, { sessionId => "sess-1" });
    } elsif ($method eq "session/prompt") {
        my $text = $message->{params}{prompt}[0]{text};
        if ($text eq "die") {
            print STDERR "fake agent: dying on request\n";
            exit 7;
        }
        send_message({ jsonrpc => "2.0", method => "session/update", params => {
            sessionId => $message->{params}{sessionId},
            update => { sessionUpdate => "agent_message_chunk", content => { type => "text", text => "echo: $text" } },
        } });
        reply($id, { stopReason => "end_turn" });
    } elsif (defined $id) {
        send_message({ jsonrpc => "2.0", id => $id, error => { code => -32601, message => "no" } });
    }
}
print STDERR "fake agent: end of input\n";
exit 3;
"""#

@Suite(.serialized, .timeLimit(.minutes(1)))
final class ChildProcessTests {
    private let directory: URL

    init() throws {
        // A test that writes to a dead child must fail, not take the whole test process with it.
        signal(SIGPIPE, SIG_IGN)
        directory = FileManager.default.temporaryDirectory.appending(path: "acpkit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func script(_ name: String, _ contents: String) throws -> String {
        let url = directory.appending(path: name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func fakeAgent() throws -> StdioTransport {
        try StdioTransport(executable: "/usr/bin/perl", arguments: [script("agent.pl", fakeAgentScript)], currentDirectory: directory.path)
    }

    /// Runs `body`, then always stops the process, so a failing test leaves nothing behind.
    private func withProcess(_ process: ChildProcess, _ body: () async throws -> Void) async throws {
        do {
            try await body()
            await process.shutdown(gracePeriod: .milliseconds(200), terminateTimeout: .seconds(1))
        } catch {
            await process.shutdown(gracePeriod: .milliseconds(200), terminateTimeout: .seconds(1))
            throw error
        }
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    /// Waits for a process that is not our child to disappear. A killed orphan stays a zombie
    /// until launchd reaps it, which takes a moment.
    private func waitUntilGone(_ pid: pid_t, timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while isAlive(pid) {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func readLine(from output: AsyncStream<Data>) async -> String? {
        var collected = Data()
        for await chunk in output {
            collected.append(chunk)
            if let newline = collected.firstIndex(of: 0x0A) {
                return String(decoding: collected[..<newline], as: UTF8.self)
            }
        }
        return nil
    }

    @Test func roundTripThroughRealPipes() async throws {
        let transport = try fakeAgent()
        let client = ACPClient(transport: transport)
        try await withProcess(transport.process) { () async throws in
            var events = client.events.makeAsyncIterator()
            let initialized = try await client.initialize(clientInfo: Implementation(name: "tests", version: "1"))
            #expect(initialized.agentCapabilities.loadSession)
            let session = try await client.newSession(cwd: directory.path)
            #expect(session.sessionId == "sess-1")

            // U+2028 is legal unescaped JSON, and a line splitter that honours it would cut this in half.
            let tricky = "a\u{2028}b\u{2029}c \u{1F600} \"quoted\" back\\slash /path"
            try await client.prompt(sessionId: "sess-1", blocks: [.text(tricky)])
            #expect(await events.next()?.update == .agentMessageChunk(ContentChunk(content: .text("echo: " + tricky))))
            #expect(await events.next() == .promptFinished(sessionId: "sess-1", result: .success(PromptResponse(stopReason: .endTurn))))

            // Far more than a pipe buffer holds, in both directions at once.
            let long = String(repeating: "0123456789abcdef", count: 64 * 1024)
            try await client.prompt(sessionId: "sess-1", blocks: [.text(long)])
            #expect(await events.next()?.update == .agentMessageChunk(ContentChunk(content: .text("echo: " + long))))
            #expect(await events.next()?.isPromptFinished == true)

            await client.shutdown()
            #expect(await events.next() == .closed(.closedByClient))
        }
        // It exits at end of input, so shutdown never had to signal it.
        #expect(transport.process.termination == .exited(3))
        #expect(transport.stderrText.contains("fake agent: started"))
        // Shutdown returns as soon as the child is reaped, and the last stderr line can still be
        // in the pipe then. The client owns `output`, so we can't wait for it to end here.
        #expect(await waitUntil { transport.stderrText.contains("fake agent: end of input") })
    }

    @Test func exitIsReportedAsTheCloseReason() async throws {
        let transport = try fakeAgent()
        let client = ACPClient(transport: transport)
        try await withProcess(transport.process) { () async throws in
            var events = client.events.makeAsyncIterator()
            _ = try await client.initialize(clientInfo: Implementation(name: "tests", version: "1"))
            try await client.prompt(sessionId: "sess-1", blocks: [.text("die")])
            #expect(await events.next() == .promptFinished(sessionId: "sess-1", result: .failure(.connectionClosed(.exited(code: 7)))))
            #expect(await events.next() == .closed(.exited(code: 7)))
            #expect(await events.next() == nil)
            #expect(transport.stderrText.contains("dying on request"))
        }
    }

    @Test func stderrKeepsOnlyTheTail() async throws {
        let process = try ChildProcess(
            executable: "/usr/bin/perl",
            arguments: ["-e", #"print STDERR "head\n"; print STDERR ("x" x 100) . "\n" for 1..2000; print STDERR "tail\n"; close STDOUT;"#]
        )
        try await withProcess(process) { () async throws in
            #expect(try await process.waitForExit() == .exited(0))
            // The output stream ends only once stderr has been read to the end too.
            for await _ in process.output {}
            let text = process.stderrText
            #expect(text.hasSuffix("tail\n"))
            #expect(!text.contains("head"))
            #expect(text.utf8.count == ChildProcess.stderrCapacity)
        }
    }

    @Test func exitCodeAndSignalAreReported() async throws {
        let exits = try ChildProcess(executable: "/bin/sh", arguments: ["-c", "exit 42"])
        #expect(try await exits.waitForExit() == .exited(42))
        let killed = try ChildProcess(executable: "/bin/sh", arguments: ["-c", "kill -KILL $$"])
        #expect(try await killed.waitForExit() == .signaled(SIGKILL))
        #expect(exits.processGroup == exits.pid)
    }

    @Test func childRunsInItsOwnSessionWithTheGivenEnvironmentAndDirectory() async throws {
        let process = try ChildProcess(
            executable: "sh",
            arguments: ["-c", #"echo "$(ps -o pgid= -p $$ | tr -d ' ') $ACP_TEST_VALUE $(pwd -P)""#],
            environment: ["PATH": "/usr/bin:/bin", "ACP_TEST_VALUE": "hello"],
            currentDirectory: directory.path
        )
        try await withProcess(process) { () async throws in
            let line = await readLine(from: process.output)
            // Foundation's symlink resolution drops /private, pwd -P does not.
            let resolved = try #require(realpath(directory.path, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            })
            #expect(line == "\(process.pid) hello \(resolved)")
        }
    }

    @Test func missingExecutableThrowsAClearError() {
        #expect(throws: ChildProcessError.executableNotFound("/nonexistent/agent-binary")) {
            try ChildProcess(executable: "/nonexistent/agent-binary")
        }
        #expect(throws: ChildProcessError.executableNotFound("no-such-agent-xyz")) {
            try ChildProcess(executable: "no-such-agent-xyz", environment: ["PATH": "/usr/bin:/bin"])
        }
        #expect(throws: ChildProcessError.notExecutable("/etc/hosts")) {
            try ChildProcess(executable: "/etc/hosts")
        }
        #expect(ChildProcessError.executableNotFound("/x").description == "No executable found at /x")
    }

    @Test func writingAfterExitThrows() async throws {
        let process = try ChildProcess(executable: "/bin/sh", arguments: ["-c", "exit 0"])
        #expect(try await process.waitForExit() == .exited(0))
        await #expect(throws: ChildProcessError.brokenPipe) {
            try await process.write(Data("hello\n".utf8))
        }
        process.closeInput()
        await #expect(throws: ChildProcessError.inputClosed) {
            try await process.write(Data("again\n".utf8))
        }
    }

    @Test func sendingAfterExitClosesTheConnection() async throws {
        let transport = try StdioTransport(executable: "/bin/sh", arguments: ["-c", "exit 5"])
        let client = ACPClient(transport: transport)
        var events = client.events.makeAsyncIterator()
        #expect(await events.next() == .closed(.exited(code: 5)))
        await #expect(throws: ACPError.connectionClosed(.exited(code: 5))) {
            try await client.newSession(cwd: "/")
        }
    }

    @Test func shutdownEndsAProcessThatExitsOnEndOfInput() async throws {
        let process = try ChildProcess(executable: "/bin/cat")
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await process.shutdown(gracePeriod: .seconds(10)) == .exited(0))
        #expect(clock.now - start < .seconds(5))
    }

    @Test func shutdownSendsSIGTERMWhenEndOfInputIsIgnored() async throws {
        let process = try ChildProcess(executable: "/usr/bin/perl", arguments: ["-e", "sleep 1000"])
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await process.shutdown(gracePeriod: .milliseconds(200), terminateTimeout: .seconds(10)) == .signaled(SIGTERM))
        #expect(clock.now - start < .seconds(8))
    }

    @Test func shutdownSendsSIGKILLWhenSIGTERMIsIgnored() async throws {
        let process = try ChildProcess(
            executable: "/usr/bin/perl",
            arguments: ["-e", #"$SIG{TERM} = "IGNORE"; $| = 1; print "ready\n"; sleep 1000 while 1;"#]
        )
        #expect(await readLine(from: process.output) == "ready")
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await process.shutdown(gracePeriod: .milliseconds(100), terminateTimeout: .milliseconds(300)) == .signaled(SIGKILL))
        #expect(clock.now - start < .seconds(8))
    }

    @Test func shutdownKillsGrandchildrenWithTheGroup() async throws {
        let process = try ChildProcess(executable: "/bin/sh", arguments: ["-c", "sleep 1000 & echo $!; wait"])
        let line = await readLine(from: process.output)
        let grandchild = try #require(line.flatMap { pid_t($0) })
        #expect(isAlive(grandchild))
        #expect(await process.shutdown(gracePeriod: .milliseconds(100), terminateTimeout: .seconds(5)) == .signaled(SIGTERM))
        #expect(await waitUntilGone(grandchild))
    }

    @Test func shutdownStopsWhatTheChildLeftBehind() async throws {
        // The child exits cleanly at end of input but leaves a background process holding stdout.
        let process = try ChildProcess(executable: "/bin/sh", arguments: ["-c", "sleep 1000 & echo $!; read line; exit 0"])
        let line = await readLine(from: process.output)
        let leftover = try #require(line.flatMap { pid_t($0) })
        #expect(await process.shutdown(gracePeriod: .seconds(5), terminateTimeout: .seconds(5)) == .exited(0))
        #expect(await waitUntilGone(leftover))
        // Output ends even though the leftover held the pipe open until it was killed.
        for await _ in process.output {}
    }

    @Test func terminateNowSignalsAtOnce() async throws {
        let process = try ChildProcess(executable: "/usr/bin/perl", arguments: ["-e", "sleep 1000"])
        process.terminateNow()
        #expect(try await process.waitForExit() == .signaled(SIGTERM))
    }

    @Test func anExitedGroupIsNeverSignalledAgain() async throws {
        let process = try ChildProcess(executable: "/usr/bin/true")
        #expect(try await process.waitForExit() == .exited(0))
        // Reaping and probing the empty group happen before the exit is reported.
        #expect(process.isGroupGone)
        process.terminateNow()
        process.signalGroup(SIGKILL)
        await process.shutdown(gracePeriod: .milliseconds(50), terminateTimeout: .milliseconds(50))
        #expect(process.sentSignals.isEmpty)
    }

    @Test func membersLeftBehindAreSignalledUntilTheGroupIsEmpty() async throws {
        let process = try ChildProcess(executable: "/bin/sh", arguments: ["-c", "sleep 1000 & echo $!; exit 0"])
        let line = await readLine(from: process.output)
        let leftover = try #require(line.flatMap { pid_t($0) })
        #expect(try await process.waitForExit() == .exited(0))
        #expect(!process.isGroupGone)

        process.terminateNow()
        #expect(process.sentSignals == [SIGTERM])
        #expect(await waitUntilGone(leftover))
        // The next attempt finds the group empty and from then on sends nothing.
        process.signalGroup(SIGTERM)
        #expect(process.isGroupGone)
        process.terminateNow()
        #expect(process.sentSignals == [SIGTERM])
    }

    @Test func waitingWithATimeoutGivesUp() async throws {
        let process = try ChildProcess(executable: "/bin/cat")
        try await withProcess(process) { () async throws in
            #expect(await process.waitForExit(timeout: .milliseconds(50)) == nil)
            #expect(process.termination == nil)
        }
        #expect(process.termination == .exited(0))
    }
}
