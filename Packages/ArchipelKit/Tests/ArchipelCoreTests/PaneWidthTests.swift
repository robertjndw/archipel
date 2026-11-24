import Foundation
import Testing
@testable import ArchipelCore

struct PaneWidthTests {
    let a = makeSession("a"), b = makeSession("b"), c = makeSession("c")

    /// A workspace with one worktree whose sessions a, b and c each have a pane of their own.
    func threePanes() throws -> (ws: Workspace, worktree: Worktree.ID) {
        var ws = Workspace()
        let project = Project(name: "p", folderURL: URL(fileURLWithPath: "/tmp/p"))
        ws.addProject(project, to: ws.islands[0].id)
        let worktree = makeWorktree("p", isMain: true)
        ws.addWorktree(worktree, to: project.id)
        for session in [a, b, c] { ws.addSession(session, to: worktree.id) }
        _ = try ws.splitTab(id: #require(ws.tab(showing: b.id)).id).unwrapped()
        _ = try ws.splitTab(id: #require(ws.tab(showing: c.id)).id).unwrapped()
        return (ws, worktree.id)
    }

    func shares(_ ws: Workspace, _ id: Worktree.ID) -> [Double] { ws.worktree(id: id)!.paneWidthShares }

    @Test func panesShareTheWidthEquallyUntilADividerIsMoved() throws {
        let (ws, id) = try threePanes()
        #expect(ws.worktree(id: id)?.panes.map(\.widthShare) == [nil, nil, nil])
        let third: Double = 1 / 3
        #expect(shares(ws, id) == [third, third, third])
        #expect(makeWorktree().paneWidthShares == [1])
    }

    @Test func sharesAreStoredAsFractionsOfTheWholeWidth() throws {
        var (ws, id) = try threePanes()
        ws.setPaneWidthShares([300, 100, 100], in: id)
        #expect(shares(ws, id) == [0.6, 0.2, 0.2])
        #expect(ws.worktree(id: id)?.panes.map(\.widthShare) == [0.6, 0.2, 0.2])
    }

    @Test(arguments: [[1.0, 1.0], [1.0, 0.0, 1.0], [1.0, -1.0, 1.0], [1.0, .nan, 1.0], [1.0, .infinity, 1.0]])
    func sharesThatDoNotFitThePanesAreIgnored(bad: [Double]) throws {
        var (ws, id) = try threePanes()
        ws.setPaneWidthShares([2, 1, 1], in: id)
        ws.setPaneWidthShares(bad, in: id)
        #expect(shares(ws, id) == [0.5, 0.25, 0.25])
    }

    @Test func splittingStartsOverWithEqualWidths() throws {
        var (ws, id) = try threePanes()
        ws.setPaneWidthShares([2, 1, 1], in: id)
        let d = makeSession("d")
        ws.addSession(d, to: id)
        #expect(shares(ws, id) == [0.5, 0.25, 0.25], "A new tab in an existing pane leaves the dividers alone.")

        _ = try ws.splitTab(id: #require(ws.tab(showing: d.id)).id).unwrapped()
        #expect(ws.worktree(id: id)?.panes.map(\.widthShare) == [nil, nil, nil, nil])
        #expect(shares(ws, id) == [0.25, 0.25, 0.25, 0.25])
    }

    @Test func closingAPaneStartsOverWithEqualWidths() throws {
        var (ws, id) = try threePanes()
        ws.setPaneWidthShares([2, 1, 1], in: id)
        ws.closeTab(id: try #require(ws.tab(showing: b.id)).id)
        #expect(shares(ws, id) == [0.5, 0.5])
        #expect(invariantsHold(ws))
    }

    @Test func focusingAndSelectingKeepTheWidths() throws {
        var (ws, id) = try threePanes()
        ws.setPaneWidthShares([2, 1, 1], in: id)
        ws.focusPane(id: try #require(ws.worktree(id: id)?.panes.first?.id))
        ws.selectSession(b.id)
        #expect(shares(ws, id) == [0.5, 0.25, 0.25])
    }

    @Test func widthsSurviveEncoding() throws {
        var (ws, id) = try threePanes()
        ws.setPaneWidthShares([2, 1, 1], in: id)
        let back = try JSONDecoder().decode(Workspace.self, from: JSONEncoder().encode(ws))
        #expect(back == ws)
        #expect(shares(back, id) == [0.5, 0.25, 0.25])
    }

    @Test func panesSavedWithoutAWidthDecodeAsEqual() throws {
        let tab = UUID(), other = UUID(), first = UUID(), second = UUID()
        let s1 = makeSession("one"), s2 = makeSession("two")
        var worktree = makeWorktree(sessions: [s1, s2])
        worktree.panes = [
            Pane(id: first, tabs: [Tab(id: tab, content: .session(s1.id))], selectedTabID: tab),
            Pane(id: second, tabs: [Tab(id: other, content: .session(s2.id))], selectedTabID: other),
        ]
        let data = try JSONEncoder().encode(worktree)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let panes = try #require(json["panes"] as? [[String: Any]])
        // An unset width is left out, so this is what a file written before widths existed holds.
        #expect(panes.count == 2 && panes.allSatisfy { $0["widthShare"] == nil })

        let decoded = try JSONDecoder().decode(Worktree.self, from: data)
        #expect(decoded.panes.map(\.id) == [first, second])
        #expect(decoded.paneWidthShares == [0.5, 0.5])
    }

    @Test func aWidthOnOnlySomePanesIsDropped() throws {
        let s1 = makeSession("one"), s2 = makeSession("two")
        var worktree = makeWorktree(sessions: [s1, s2])
        worktree.panes = [
            Pane(tabs: [Tab(content: .session(s1.id))], widthShare: 0.7),
            Pane(tabs: [Tab(content: .session(s2.id))]),
        ]
        let decoded = try JSONDecoder().decode(Worktree.self, from: JSONEncoder().encode(worktree))
        #expect(decoded.panes.map(\.widthShare) == [nil, nil])
        #expect(decoded.paneWidthShares == [0.5, 0.5])
    }

    /// Shares written by hand need not add up to 1; they are read as parts of the whole.
    @Test func handWrittenSharesAreReadAsParts() throws {
        let s1 = makeSession("one"), s2 = makeSession("two")
        var worktree = makeWorktree(sessions: [s1, s2])
        worktree.panes = [
            Pane(tabs: [Tab(content: .session(s1.id))], widthShare: 1),
            Pane(tabs: [Tab(content: .session(s2.id))], widthShare: 3),
        ]
        let decoded = try JSONDecoder().decode(Worktree.self, from: JSONEncoder().encode(worktree))
        #expect(decoded.paneWidthShares == [0.25, 0.75])
    }

    // MARK: Moving the focus

    @Test func adjacentPaneWrapsAroundInBothDirections() throws {
        var (ws, id) = try threePanes()
        let panes = try #require(ws.worktree(id: id)?.panes.map(\.id))
        ws.focusPane(id: panes[2])
        #expect(ws.worktree(id: id)?.paneID(adjacentToFocused: 1) == panes[0])
        #expect(ws.worktree(id: id)?.paneID(adjacentToFocused: -1) == panes[1])

        ws.focusPane(id: panes[0])
        #expect(ws.worktree(id: id)?.paneID(adjacentToFocused: 1) == panes[1])
        #expect(ws.worktree(id: id)?.paneID(adjacentToFocused: -1) == panes[2])
    }

    @Test func aSinglePaneHasNoNeighbour() {
        let worktree = makeWorktree(sessions: [a, b])
        #expect(worktree.paneID(adjacentToFocused: 1) == nil)
        #expect(worktree.paneID(adjacentToFocused: -1) == nil)
    }
}

struct SplitSharesTests {
    @Test func equalSharesPutTheDividersWhereBalancingDid() {
        // 1002 wide with two 1 point dividers leaves 1000 for three panes.
        let positions = SplitShares.dividerPositions(shares: [1, 1, 1], total: 1002, thickness: 1)
        #expect(positions.count == 2)
        #expect(abs(positions[0] - 1000.0 / 3) < 0.001)
        #expect(abs(positions[1] - (2000.0 / 3 + 1)) < 0.001)
    }

    @Test func sharesNeedNotAddUpToOne() {
        #expect(SplitShares.dividerPositions(shares: [3, 1], total: 801, thickness: 1) == [600])
        #expect(SplitShares.dividerPositions(shares: [0.75, 0.25], total: 801, thickness: 1) == [600])
    }

    @Test(arguments: [[Double](), [1.0], [1.0, 0.0], [1.0, -2.0]])
    func nothingToPlace(shares: [Double]) {
        #expect(SplitShares.dividerPositions(shares: shares, total: 800, thickness: 1).isEmpty)
    }

    @Test func noRoomPlacesNothing() {
        #expect(SplitShares.dividerPositions(shares: [1, 1], total: 1, thickness: 1).isEmpty)
    }

    @Test func widthsBecomeFractions() {
        #expect(SplitShares.shares(widths: [600, 200]) == [0.75, 0.25])
        #expect(SplitShares.shares(widths: [500]) == [1])
    }

    @Test(arguments: [[Double](), [400.0, 0.0], [400.0, -1.0]])
    func aCollapsedPaneGivesNoShares(widths: [Double]) {
        #expect(SplitShares.shares(widths: widths) == nil)
    }

    @Test func placingAndMeasuringRoundTrip() throws {
        let shares = [0.5, 0.2, 0.3]
        let positions = SplitShares.dividerPositions(shares: shares, total: 1002, thickness: 1)
        let widths = [positions[0], positions[1] - positions[0] - 1, 1002 - positions[1] - 1]
        let measured = try #require(SplitShares.shares(widths: widths))
        for (measured, expected) in zip(measured, shares) { #expect(abs(measured - expected) < 0.0001) }
    }
}

struct InteractiveShellTests {
    @Test(arguments: [
        ["-zsh"], ["/bin/zsh", "-l"], ["/bin/sh", "-l"], ["bash"], ["bash", "--login", "-i"],
        ["/opt/homebrew/bin/fish", "-l"], ["fish", "--private"],
    ])
    func shellsWaitingForInput(arguments: [String]) {
        #expect(AgentProcessMatcher.isInteractiveShell(name: "zsh", arguments: arguments))
    }

    @Test(arguments: [
        ["/bin/sh", "./build.sh"], ["/bin/zsh", "-c", "npm run dev"], ["zsh", "-lc", "make"],
        ["bash", "--rcfile", "x"], ["node", "server.js"], ["ssh", "host"], ["vim"],
    ])
    func shellsRunningSomethingAndOtherPrograms(arguments: [String]) {
        #expect(!AgentProcessMatcher.isInteractiveShell(name: "zsh", arguments: arguments))
    }

    @Test func theKernelNameStandsInForUnreadableArguments() {
        #expect(AgentProcessMatcher.isInteractiveShell(name: "zsh", arguments: []))
        #expect(!AgentProcessMatcher.isInteractiveShell(name: "node", arguments: []))
    }
}
