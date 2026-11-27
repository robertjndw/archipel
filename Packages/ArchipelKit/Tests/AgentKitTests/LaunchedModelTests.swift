import AgentKit
import Testing

struct LaunchedModelTests {
    @Test func readsTheLongFlagWithASeparateValue() {
        #expect(LaunchedModel.name(in: ["--model", "opus", "--verbose"]) == "opus")
    }

    @Test func readsTheLongFlagWithAnEquals() {
        #expect(LaunchedModel.name(in: ["--model=gpt-5.5"]) == "gpt-5.5")
    }

    @Test func readsTheShortFlag() {
        #expect(LaunchedModel.name(in: ["-m", "gpt-5.5"]) == "gpt-5.5")
    }

    @Test func readsCodexsConfigOverride() {
        #expect(LaunchedModel.name(in: ["-c", "model=gpt-5.5"]) == "gpt-5.5")
        #expect(LaunchedModel.name(in: ["-c", "model=\"gpt-5.5\""]) == "gpt-5.5")
    }

    @Test func ignoresOtherConfigKeys() {
        #expect(LaunchedModel.name(in: ["-c", "model_reasoning_effort=high"]) == nil)
    }

    @Test func theLastOneWins() {
        #expect(LaunchedModel.name(in: ["--model", "opus", "-m", "sonnet"]) == "sonnet")
    }

    @Test func noModelGivesNil() {
        #expect(LaunchedModel.name(in: []) == nil)
        #expect(LaunchedModel.name(in: ["--verbose", "--resume", "abc"]) == nil)
    }

    @Test func aFlagWithoutAValueGivesNil() {
        #expect(LaunchedModel.name(in: ["--model"]) == nil)
        #expect(LaunchedModel.name(in: ["--model="]) == nil)
    }
}
