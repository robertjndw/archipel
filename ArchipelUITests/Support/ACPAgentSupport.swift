import Foundation
import XCTest

/// One message the stand-in chat agent received from the app, or an answer it was given.
struct ChatAgentMessage: Decodable, Equatable {
    var method: String
    var sessionId: String?
    /// What the user typed, for `session/prompt`; the option chosen, for `permission-answer`.
    var text: String?
}

/// Where the stand-in `opencode` writes down what happened, and the trigger a test pulls.
struct ChatAgentStub {
    /// Every launch, chat and terminal alike, in the format of `installRecordingAgentStub(named:)`.
    let launches: URL
    fileprivate let log: URL
    fileprivate let finishTrigger: URL

    /// Everything the agent received, oldest first. A line still being written is skipped and
    /// shows up on the next read.
    func received() throws -> [ChatAgentMessage] {
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap {
            try? JSONDecoder().decode(ChatAgentMessage.self, from: Data($0.utf8))
        }
    }

    func received(_ method: String) throws -> [ChatAgentMessage] {
        try received().filter { $0.method == method }
    }

    /// The text of every prompt the agent was sent, oldest first.
    func prompts() throws -> [String] {
        try received("session/prompt").compactMap(\.text)
    }

    /// The option the app answered each permission request with, or "cancelled".
    func permissionAnswers() throws -> [String] {
        try received("permission-answer").compactMap(\.text)
    }

    /// The launches that served the chat, as opposed to those that ran in a terminal.
    func chatLaunches() throws -> [AgentLaunch] {
        try AgentLaunch.all(in: launches).filter { $0.arguments == ["acp"] }
    }

    /// Lets a turn started with a prompt containing "slow" finish normally.
    func finishSlowTurn() throws {
        try Data().write(to: finishTrigger)
    }
}

extension Sandbox {
    /// An `opencode` that serves the Agent Client Protocol when the app runs it as `opencode acp`
    /// for a chat, and otherwise stands in for the terminal CLI like the recording stub. OpenCode
    /// needs no registry download: the app runs whatever `opencode` the PATH finds with `acp`.
    ///
    /// The prompt picks what a turn does, so a test chooses by what it types:
    /// - "crash": one chunk, then the process exits with status 3.
    /// - "permission": an edit of notes.txt that asks first, with OpenCode's own options. Allowing
    ///   it completes the turn, rejecting fails the edit and cancels the turn.
    /// - "tool": a read of README.md that completes, then "I read README.md."
    /// - "slow": "Working slowly.", then nothing until session/cancel or `finishSlowTurn()`.
    /// - anything else: "Echo: <prompt>", streamed in two chunks.
    ///
    /// Conversations are kept on disk in the sandbox, so `session/load` replays them after a
    /// relaunch, a restart or a switch to the terminal and back. Session ids count up from
    /// `ses_stub1`. Written in Perl with core modules only, because a shell script cannot read
    /// JSON-RPC sensibly.
    func installChatAgentStub() throws -> ChatAgentStub {
        let stub = ChatAgentStub(
            launches: root.appending(path: "opencode-launches.txt"),
            log: root.appending(path: "opencode-acp-log.txt"),
            finishTrigger: root.appending(path: "opencode-finish-slow")
        )
        let script = #"""
            #!/usr/bin/perl
            use strict;
            use warnings;
            use Cwd qw(getcwd);
            use IO::Handle;
            use IO::Select;
            use JSON::PP;

            STDOUT->autoflush(1);
            # The app may close the pipe while a reply is still on its way.
            $SIG{PIPE} = 'IGNORE';

            my $root = '\#(root.path)';
            my $launches = "$root/opencode-launches.txt";
            my $log = "$root/opencode-acp-log.txt";
            my $state = "$root/opencode-acp-state";
            my $finishSlow = "$root/opencode-finish-slow";

            # The same record as the recording stub's, in one write so two launches never interleave.
            {
                my $record = 'session=' . ($ENV{ARCHIPEL_SESSION_ID} // '') . "\n"
                    . 'socket=' . ($ENV{ARCHIPEL_SOCKET} // '') . "\n"
                    . 'cwd=' . getcwd() . "\n";
                $record .= "argument=$_\n" for @ARGV;
                $record .= "\#(Self.endOfLaunch)\n";
                open(my $handle, '>>', $launches) or die "cannot write the launch record: $!";
                print $handle $record;
                close($handle);
            }

            # The terminal interface runs `opencode -s <id>`: nothing to serve, only to stay alive.
            unless (@ARGV && $ARGV[0] eq 'acp') {
                sleep 1 while 1;
            }

            mkdir($state) unless -d $state;
            my $json = JSON::PP->new->utf8->canonical;
            my $cwd = getcwd();
            my $mode = 'build';
            my $nextRequestID = 0;
            my $nextMessageID = 0;

            # Files the tests read

            sub append_line {
                my ($path, $line) = @_;
                open(my $handle, '>>', $path) or die "cannot append to $path: $!";
                print $handle "$line\n";
                close($handle);
            }

            sub log_event {
                my (%entry) = @_;
                append_line($log, $json->encode(\%entry));
            }

            sub history_file { "$state/$_[0].jsonl" }

            sub remember {
                my ($sessionID, $role, $text) = @_;
                append_line(history_file($sessionID), $json->encode({ role => $role, text => $text }));
            }

            sub history {
                my ($sessionID) = @_;
                open(my $handle, '<', history_file($sessionID)) or return;
                my @entries = map { $json->decode($_) } grep { /\S/ } <$handle>;
                close($handle);
                return @entries;
            }

            # A counter on disk, so a session started after a relaunch or a restart gets an id of its own.
            sub new_session_id {
                my $counter = "$state/counter";
                my $count = 0;
                if (open(my $handle, '<', $counter)) {
                    $count = <$handle> // 0;
                    close($handle);
                }
                $count += 1;
                open(my $handle, '>', $counter) or die "cannot write $counter: $!";
                print $handle $count;
                close($handle);
                return "ses_stub$count";
            }

            # Talking JSON-RPC

            sub send_message { print $json->encode($_[0]) . "\n" }

            sub respond { send_message({ jsonrpc => '2.0', id => $_[0], result => $_[1] }) }

            sub respond_error {
                my ($id, $code, $message) = @_;
                send_message({ jsonrpc => '2.0', id => $id, error => { code => $code, message => $message } });
            }

            sub update {
                my ($sessionID, $update) = @_;
                send_message({ jsonrpc => '2.0', method => 'session/update', params => { sessionId => $sessionID, update => $update } });
            }

            sub message_chunk {
                my ($sessionID, $kind, $messageID, $text) = @_;
                update($sessionID, { sessionUpdate => $kind, messageId => $messageID, content => { type => 'text', text => $text } });
            }

            my $buffer = '';
            my $input = IO::Select->new(\*STDIN);

            # The next message from the app, or undef when none came within `$timeout` seconds (no timeout
            # waits for good). Read with sysread into a buffer of our own: Perl's buffered <STDIN> and
            # select() disagree about what is still unread.
            sub next_message {
                my ($timeout) = @_;
                while (1) {
                    while ($buffer =~ s/^([^\n]*)\n//) {
                        my $message = eval { $json->decode($1) };
                        next unless ref $message eq 'HASH';
                        if (defined $message->{method}) {
                            my $params = $message->{params} // {};
                            my %entry = (method => $message->{method});
                            $entry{sessionId} = $params->{sessionId} if defined $params->{sessionId};
                            $entry{text} = prompt_text($params) if $message->{method} eq 'session/prompt';
                            log_event(%entry);
                        }
                        return $message;
                    }
                    return undef if defined $timeout && !$input->can_read($timeout);
                    my $read = sysread(STDIN, $buffer, 65536, length $buffer);
                    # End of input is how the app stops a chat.
                    exit 0 unless $read;
                }
            }

            sub prompt_text {
                my ($params) = @_;
                return join '', map { $_->{text} // '' } grep { ($_->{type} // '') eq 'text' } @{ $params->{prompt} // [] };
            }

            # The agent

            sub config_options {
                return [{
                    id => 'mode', name => 'Session Mode', category => 'mode', type => 'select', currentValue => $mode,
                    options => [
                        { value => 'build', name => 'Build', description => 'The default agent.' },
                        { value => 'plan', name => 'Plan', description => 'Read-only agent.' },
                    ],
                }];
            }

            # Answers everything outside a turn, and whatever arrives during one that the turn does not wait for.
            sub handle {
                my ($message) = @_;
                my $method = $message->{method};
                # A response nobody waits for any more.
                return unless defined $method;
                my $id = $message->{id};
                my $params = $message->{params} // {};

                if ($method eq 'initialize') {
                    respond($id, {
                        protocolVersion => 1,
                        agentCapabilities => {
                            loadSession => JSON::PP::true,
                            promptCapabilities => { embeddedContext => JSON::PP::true, image => JSON::PP::false },
                        },
                        authMethods => [],
                        agentInfo => { name => 'OpenCode', version => '0.0.0-stub' },
                    });
                } elsif ($method eq 'session/new') {
                    my $sessionID = new_session_id();
                    # Exists from here on, as a real session does, so loading it later finds it.
                    append_line(history_file($sessionID), '');
                    respond($id, { sessionId => $sessionID, configOptions => config_options() });
                } elsif ($method eq 'session/load') {
                    my $sessionID = $params->{sessionId} // '';
                    unless (-e history_file($sessionID)) {
                        respond_error($id, -32002, "Session not found: $sessionID");
                        return;
                    }
                    # The replay comes before the response, the way OpenCode sends it.
                    for my $entry (history($sessionID)) {
                        my $kind = $entry->{role} eq 'user' ? 'user_message_chunk' : 'agent_message_chunk';
                        message_chunk($sessionID, $kind, 'msg_replay' . ++$nextMessageID, $entry->{text});
                    }
                    respond($id, { configOptions => config_options() });
                } elsif ($method eq 'session/set_config_option') {
                    $mode = $params->{value} if ($params->{configId} // '') eq 'mode';
                    respond($id, { configOptions => config_options() });
                } elsif ($method eq 'session/prompt') {
                    run_turn($id, $params);
                } elsif (defined $id) {
                    respond_error($id, -32601, "Method not found: $method");
                }
                # Any other notification, session/cancel outside a turn included, needs no answer.
            }

            # The prompts and what each one does are listed on `installChatAgentStub()`.
            sub run_turn {
                my ($id, $params) = @_;
                my $sessionID = $params->{sessionId};
                my $text = prompt_text($params);
                my $messageID = 'msg_turn' . ++$nextMessageID;
                remember($sessionID, 'user', $text);

                if ($text =~ /crash/) {
                    message_chunk($sessionID, 'agent_message_chunk', $messageID, 'About to crash.');
                    exit 3;
                } elsif ($text =~ /permission/) {
                    permission_turn($id, $sessionID, $messageID);
                } elsif ($text =~ /tool/) {
                    my $call = 'call_read_' . $nextMessageID;
                    update($sessionID, {
                        sessionUpdate => 'tool_call', toolCallId => $call, title => 'Read README.md', kind => 'read',
                        status => 'pending', locations => [{ path => "$cwd/README.md" }],
                    });
                    update($sessionID, {
                        sessionUpdate => 'tool_call_update', toolCallId => $call, status => 'completed',
                        content => [{ type => 'content', content => { type => 'text', text => "README contents\n" } }],
                    });
                    finish_turn($id, $sessionID, $messageID, 'end_turn', 'I read README.md.');
                } elsif ($text =~ /slow/) {
                    slow_turn($id, $sessionID, $messageID);
                } else {
                    finish_turn($id, $sessionID, $messageID, 'end_turn', 'Echo: ', $text);
                }
            }

            # Streams the reply in the chunks given, then ends the turn with `$stopReason`.
            sub finish_turn {
                my ($id, $sessionID, $messageID, $stopReason, @chunks) = @_;
                message_chunk($sessionID, 'agent_message_chunk', $messageID, $_) for @chunks;
                remember($sessionID, 'agent', join('', @chunks)) if @chunks;
                respond($id, { stopReason => $stopReason });
            }

            # One chunk, then nothing until the app cancels the turn or the test creates the trigger file.
            sub slow_turn {
                my ($id, $sessionID, $messageID) = @_;
                message_chunk($sessionID, 'agent_message_chunk', $messageID, 'Working slowly.');
                while (1) {
                    if (-e $finishSlow) {
                        unlink($finishSlow);
                        message_chunk($sessionID, 'agent_message_chunk', $messageID, ' Finished.');
                        remember($sessionID, 'agent', 'Working slowly. Finished.');
                        respond($id, { stopReason => 'end_turn' });
                        return;
                    }
                    my $message = next_message(0.1) or next;
                    if (($message->{method} // '') eq 'session/cancel') {
                        remember($sessionID, 'agent', 'Working slowly.');
                        respond($id, { stopReason => 'cancelled' });
                        return;
                    }
                    handle($message);
                }
            }

            # An edit that needs the user's approval, with the option ids and names OpenCode sends.
            sub permission_turn {
                my ($id, $sessionID, $messageID) = @_;
                my $call = 'call_write_' . $nextMessageID;
                my $toolCall = {
                    toolCallId => $call, title => 'Edit notes.txt', kind => 'edit', status => 'pending',
                    locations => [{ path => "$cwd/notes.txt" }],
                    content => [{ type => 'diff', path => "$cwd/notes.txt", oldText => "first line\n", newText => "first line\nsecond line\n" }],
                };
                update($sessionID, { sessionUpdate => 'tool_call', %$toolCall });
                my $requestID = $nextRequestID++;
                send_message({
                    jsonrpc => '2.0', id => $requestID, method => 'session/request_permission',
                    params => {
                        sessionId => $sessionID,
                        toolCall => $toolCall,
                        options => [
                            { optionId => 'once', kind => 'allow_once', name => 'Allow once' },
                            { optionId => 'always', kind => 'allow_always', name => 'Always allow' },
                            { optionId => 'reject', kind => 'reject_once', name => 'Reject' },
                        ],
                    },
                });

                my $outcome;
                while (1) {
                    my $message = next_message();
                    if (!defined $message->{method} && defined $message->{id} && $message->{id} eq $requestID) {
                        $outcome = $message->{result}{outcome} // {};
                        last;
                    }
                    # After session/cancel the client still answers the request, with the cancelled
                    # outcome, so the loop keeps waiting for that.
                    handle($message) unless ($message->{method} // '') eq 'session/cancel';
                }
                my $answer = ($outcome->{outcome} // '') eq 'selected' ? $outcome->{optionId} : 'cancelled';
                log_event(method => 'permission-answer', sessionId => $sessionID, text => $answer);

                if ($answer eq 'once' || $answer eq 'always') {
                    update($sessionID, { sessionUpdate => 'tool_call_update', toolCallId => $call, status => 'completed' });
                    finish_turn($id, $sessionID, $messageID, 'end_turn', 'Allowed: edited notes.txt.');
                } elsif ($answer eq 'reject') {
                    update($sessionID, {
                        sessionUpdate => 'tool_call_update', toolCallId => $call, status => 'failed',
                        content => [{ type => 'content', content => { type => 'text', text => 'The user declined this tool call' } }],
                    });
                    finish_turn($id, $sessionID, $messageID, 'cancelled');
                } else {
                    finish_turn($id, $sessionID, $messageID, 'cancelled');
                }
            }

            while (1) {
                handle(next_message());
            }

            """#
        let executable = bin.appending(path: "opencode")
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return stub
    }
}

extension ArchipelUITestCase {
    /// Waits until the chat agent has been started `count` times and returns the newest launch.
    /// Terminal launches of the same stub do not count. Fails when it was started more often.
    @discardableResult
    func waitForChatLaunch(
        _ count: Int,
        of stub: ChatAgentStub,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AgentLaunch {
        waitUntil("the chat agent was started \(count == 1 ? "once" : "\(count) times")", file: file, line: line) {
            try stub.chatLaunches().count >= count
        }
        let launches = try stub.chatLaunches()
        XCTAssertEqual(launches.count, count, "The chat agent was started more often than the test asked for.", file: file, line: line)
        return try XCTUnwrap(launches.last, file: file, line: line)
    }

    /// Waits until the agent has been sent `method`, for `sessionID` when one is given.
    func waitUntilChatAgentReceived(
        _ method: String,
        for sessionID: String? = nil,
        from stub: ChatAgentStub,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        waitUntil("the agent received \(method)\(sessionID.map { " for \($0)" } ?? "")", file: file, line: line) {
            try stub.received(method).contains { sessionID == nil || $0.sessionId == sessionID }
        }
    }
}
