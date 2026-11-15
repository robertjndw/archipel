import Foundation
import Testing
@testable import ArchipelCore

struct ProcessAttributionTests {
    private func process(_ pid: Int32, parent: Int32, sid: Int32, start: UInt64 = 1) -> ProcessEntry {
        ProcessEntry(identity: ProcessIdentity(pid: pid, startTime: start), parentPID: parent, unixSessionID: sid)
    }

    private func pids(_ identities: Set<ProcessIdentity>?) -> Set<Int32> {
        Set((identities ?? []).map(\.pid))
    }

    @Test func claimsTheTerminalsUnixSessionAndDetachedDescendants() {
        let table = [
            process(100, parent: 1, sid: 100),   // login
            process(101, parent: 100, sid: 100), // agent
            process(102, parent: 101, sid: 102), // dev server that called setsid
            process(103, parent: 102, sid: 102), // its worker
            process(200, parent: 1, sid: 200),   // another terminal
        ]
        let result = ProcessAttribution.attribute(
            [.init(key: "a", unixSessionID: 100, members: [])], among: table)
        #expect(pids(result["a"]) == [100, 101, 102, 103])
    }

    @Test func membersStayAttachedAfterTheirParentExits() {
        // The agent is gone and the server was reparented to launchd in a session of its own.
        let server = process(102, parent: 1, sid: 102)
        let worker = process(103, parent: 102, sid: 102)
        let result = ProcessAttribution.attribute(
            [.init(key: "a", unixSessionID: 100, members: [server.identity])], among: [server, worker])
        #expect(pids(result["a"]) == [102, 103])
    }

    @Test func aRecycledPidIsNotAMember() {
        let stranger = process(102, parent: 1, sid: 102, start: 99)
        let result = ProcessAttribution.attribute(
            [.init(key: "a", unixSessionID: nil, members: [ProcessIdentity(pid: 102, startTime: 1)])], among: [stranger])
        #expect(result["a"]?.isEmpty == true)
    }

    @Test func theFirstOwnerWinsASharedProcess() {
        let shared = process(102, parent: 1, sid: 102)
        let result = ProcessAttribution.attribute(
            [.init(key: "a", unixSessionID: nil, members: [shared.identity]),
             .init(key: "b", unixSessionID: nil, members: [shared.identity])],
            among: [shared])
        #expect(pids(result["a"]) == [102])
        #expect(result["b"]?.isEmpty == true)
    }

    @Test func neverSweepsInLaunchdsSession() {
        let result = ProcessAttribution.attribute(
            [.init(key: "a", unixSessionID: 1, members: [])],
            among: [process(1, parent: 0, sid: 1), process(50, parent: 1, sid: 1)])
        #expect(result["a"]?.isEmpty == true)
    }
}

struct CPUMeterTests {
    private let id = ProcessIdentity(pid: 10, startTime: 1)

    @Test func measuresTheShareOfWallTime() {
        var meter = CPUMeter()
        #expect(meter.update([id: 0], at: 0).isEmpty)
        let second = meter.update([id: 1_500_000_000], at: 1_000_000_000)
        #expect(second[id] == 150)
    }

    @Test func forgetsProcessesThatWereNotRead() {
        var meter = CPUMeter()
        _ = meter.update([id: 0], at: 0)
        _ = meter.update([:], at: 1_000_000_000)
        #expect(meter.update([id: 500_000_000], at: 2_000_000_000).isEmpty)
    }
}

struct SustainedLoadTests {
    private let id = ProcessIdentity(pid: 10, startTime: 1)
    private let start = Date(timeIntervalSince1970: 0)

    @Test func reportsOnlyAfterTheDuration() {
        var load = SustainedLoad()
        load.update([id: 95], threshold: 80, at: start)
        load.update([id: 95], threshold: 80, at: start + 60)
        #expect(load.processes(hotFor: 120, at: start + 60).isEmpty)
        load.update([id: 95], threshold: 80, at: start + 120)
        #expect(load.processes(hotFor: 120, at: start + 120) == [id])
    }

    @Test func aDipStartsTheClockOver() {
        var load = SustainedLoad()
        load.update([id: 95], threshold: 80, at: start)
        load.update([id: 10], threshold: 80, at: start + 60)
        load.update([id: 95], threshold: 80, at: start + 120)
        #expect(load.processes(hotFor: 120, at: start + 120).isEmpty)
    }
}

struct ProcessLabelTests {
    @Test(arguments: [
        ("node", ["node", "/p/node_modules/.bin/vite"], "vite"),
        ("node", ["/usr/local/bin/node", "/p/node_modules/vite/bin/vite.js", "--port", "5173"], "vite"),
        ("node", ["node", "/opt/homebrew/lib/node_modules/npm/bin/npm-cli.js", "run", "dev"], "npm run dev"),
        ("node", ["node", "--inspect", "server.js"], "server"),
        ("node", ["node", "/p/node_modules/next/dist/bin/next", "dev"], "next"),
        ("node", ["node", "/p/node_modules/tsx/dist/cli.mjs", "watch"], "tsx"),
        ("Python", ["/usr/bin/python3", "-m", "http.server"], "http.server"),
        ("node", ["node", "-e", "console.log(1)"], "node"),
        ("claude", ["claude", "--settings", "{}"], "claude"),
        ("pnpm", ["/opt/homebrew/bin/pnpm", "dev"], "pnpm dev"),
        ("zsh", [], "zsh"),
    ])
    func label(name: String, arguments: [String], expected: String) {
        #expect(ProcessLabel.label(name: name, arguments: arguments) == expected)
    }
}
