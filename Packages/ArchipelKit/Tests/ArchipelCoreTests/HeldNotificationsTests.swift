import Foundation
import Testing
@testable import ArchipelCore

struct HeldNotificationsTests {
    let a = makeSession("a"), b = makeSession("b"), c = makeSession("c"), d = makeSession("d")

    @Test func emptyHasNoSummary() {
        #expect(HeldNotifications().summary(activities: [:]) == nil)
    }

    @Test func countsAndPrefersSessionThatNeedsYou() throws {
        var held = HeldNotifications()
        held.hold(a.id)
        held.hold(b.id)
        held.hold(c.id)
        let summary = try #require(held.summary(activities: [
            a.id: SessionActivity(status: .finished, unread: true),
            b.id: SessionActivity(status: .needsAttention(.permission), unread: true),
            c.id: SessionActivity(status: .finished, unread: true),
        ]))
        #expect(summary.finished == 2)
        #expect(summary.needYou == 1)
        #expect(summary.text == "2 agents finished, 1 needs you")
        #expect(summary.sessionID == b.id)
    }

    @Test func opensMostRecentWhenNothingNeedsYou() throws {
        var held = HeldNotifications()
        held.hold(a.id)
        held.hold(b.id)
        held.hold(a.id)
        #expect(held.sessionIDs == [b.id, a.id])
        let summary = try #require(held.summary(activities: [
            a.id: SessionActivity(status: .exited(code: 1), unread: true),
            b.id: SessionActivity(status: .finished, unread: true),
        ]))
        #expect(summary.sessionID == a.id)
        #expect(summary.text == "1 agent finished, 1 session ended")
    }

    @Test func dropsWhatWasDealtWithMeanwhile() {
        var held = HeldNotifications()
        held.hold(a.id)
        held.hold(b.id)
        held.hold(d.id)
        let summary = held.summary(activities: [
            a.id: SessionActivity(status: .finished, unread: false),
            b.id: SessionActivity(status: .working),
        ])
        #expect(summary == nil)
    }

    @Test func pluralNeedYou() throws {
        var held = HeldNotifications()
        held.hold(a.id)
        held.hold(b.id)
        let summary = try #require(held.summary(activities: [
            a.id: SessionActivity(status: .needsAttention(.question), unread: true),
            b.id: SessionActivity(status: .needsAttention(.permission), unread: true),
        ]))
        #expect(summary.text == "2 need you")
        #expect(summary.sessionID == b.id)
    }

    @Test func theSummaryKnowsEverySessionItCounts() throws {
        let (a, b, c, d) = (makeSession(), makeSession(), makeSession(), makeSession())
        var held = HeldNotifications()
        for session in [a, b, c, d] { held.hold(session.id) }
        let summary = try #require(held.summary(activities: [
            a.id: SessionActivity(status: .finished, unread: true),
            b.id: SessionActivity(status: .needsAttention(.permission), unread: true),
            c.id: SessionActivity(status: .exited(code: 0), unread: true),
            // Read meanwhile, and back at work: neither is counted.
            d.id: SessionActivity(status: .working, unread: true),
        ]))
        #expect(summary.covered == [a.id, b.id, c.id])
    }

    /// "2 agents finished, 1 needs you" opens one session, and looking at that one leaves two
    /// the user has not been to.
    @Test func aSummaryIsWithdrawnWithTheLastSessionItCovers() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        var coverage = SummaryCoverage([a, b, c])
        #expect(coverage.clear(b) == false)
        #expect(coverage.clear(b) == false)
        #expect(coverage.clear(UUID()) == false)
        #expect(coverage.clear(a) == false)
        #expect(coverage.clear(c) == true)
        // Withdrawn once.
        #expect(coverage.clear(c) == false)
        var none = SummaryCoverage()
        #expect(none.clear(a) == false)
    }
}
