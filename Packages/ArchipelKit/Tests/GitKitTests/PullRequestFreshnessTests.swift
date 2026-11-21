import Testing
@testable import GitKit

struct PullRequestFreshnessTests {
    @Test func noneOnAPushedBranchIsAskedAgainBeforeAFoundPullRequest() {
        let age = Duration.seconds(90)
        let poll = Duration.seconds(300)
        #expect(PullRequestFreshness.isDue(.none, age: age, hasUpstream: true, requestedAge: poll))
        #expect(!PullRequestFreshness.isDue(.found, age: age, hasUpstream: true, requestedAge: poll))
    }

    @Test func unpushedBranchWaitsForTheLongInterval() {
        let poll = Duration.seconds(300)
        #expect(!PullRequestFreshness.isDue(.none, age: .seconds(90), hasUpstream: false, requestedAge: poll))
        #expect(PullRequestFreshness.isDue(.none, age: .seconds(300), hasUpstream: false, requestedAge: poll))
    }

    @Test func firstFailureIsRetriedSoonRepeatedOnesSlowly() {
        let poll = Duration.seconds(300)
        #expect(PullRequestFreshness.isDue(.failed(repeatedly: false), age: .seconds(60), hasUpstream: true, requestedAge: poll))
        #expect(!PullRequestFreshness.isDue(.failed(repeatedly: false), age: .seconds(10), hasUpstream: true, requestedAge: poll))
        #expect(!PullRequestFreshness.isDue(.failed(repeatedly: true), age: .seconds(60), hasUpstream: true, requestedAge: poll))
    }

    @Test func callerLimitWinsWhenShorter() {
        #expect(PullRequestFreshness.isDue(.found, age: .seconds(31), hasUpstream: true, requestedAge: .seconds(30)))
        #expect(PullRequestFreshness.isDue(.found, age: .zero, hasUpstream: true, requestedAge: .zero))
    }
}
