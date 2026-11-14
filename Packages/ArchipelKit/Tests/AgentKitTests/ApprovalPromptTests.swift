import AgentKit
import Testing

/// Screens shaped after what Claude Code and Codex draw for an approval, as `readVisibleText`
/// returns them: plain text, box drawing and cursor marker included.
struct ApprovalPromptTests {
    static let claudeBash = """
    ⏺ Bash(rm -rf build)
    ╭──────────────────────────────────────────────────────────────╮
    │ Bash command                                                 │
    │                                                              │
    │   rm -rf build                                               │
    │   Remove the build folder                                    │
    │                                                              │
    │ Do you want to proceed?                                      │
    │ ❯ 1. Yes                                                     │
    │   2. Yes, and don't ask again for rm commands in             │
    │   /Users/me/project                                          │
    │   3. No, and tell Claude what to do differently (esc)        │
    ╰──────────────────────────────────────────────────────────────╯

    """

    static let codexCommand = """
      Would you like to run the following command?

      $ rm -rf build

    › 1. Yes, proceed (y)
      2. Yes, and don't ask again for this command in this session (a)
      3. No, and tell Codex what to do differently (esc)

      Press enter to confirm or esc to cancel
    """

    static let claudePlan = """
     Would you like to proceed?

     ❯ 1. Yes, and bypass permissions
       2. Yes, and auto-accept edits
       3. Yes, and manually approve edits
       4. No, keep planning
    """

    @Test func claudeAllowsWithTheDigitOfPlainYes() throws {
        let prompt = try #require(ApprovalPrompt.parse(screen: Self.claudeBash))
        #expect(prompt.options.map(\.number) == [1, 2, 3])
        #expect(prompt.allow == .character("1"))
        #expect(prompt.deny == .escape)
        #expect(prompt.options[2].shortcut == "esc")
        #expect(prompt.options[2].label == "No, and tell Claude what to do differently")
    }

    @Test func codexAllowsWithItsShortcutLetter() throws {
        let prompt = try #require(ApprovalPrompt.parse(screen: Self.codexCommand))
        #expect(prompt.allow == .character("y"))
        #expect(prompt.deny == .escape)
    }

    @Test func picksTheNarrowestYes() throws {
        let prompt = try #require(ApprovalPrompt.parse(screen: Self.claudePlan))
        #expect(prompt.allow == .character("3"))
    }

    @Test func onlyStandingApprovalsMeansNoAllow() {
        let screen = """
        ❯ 1. Yes, and don't ask again for this command
          2. No
        """
        #expect(ApprovalPrompt.parse(screen: screen) == nil)
    }

    @Test func questionMenuIsNotAnApproval() {
        let screen = """
        Which database should I use?
        ❯ 1. Postgres
          2. SQLite
          3. Type something.
        """
        #expect(ApprovalPrompt.parse(screen: screen) == nil)
        #expect(ApprovalPrompt.trailingMenu(in: screen)?.count == 3)
    }

    @Test func menuFarAboveTheBottomIsTranscript() {
        let screen = Self.claudeBash + (1...10).map { "line \($0)" }.joined(separator: "\n")
        #expect(ApprovalPrompt.parse(screen: screen) == nil)
    }

    @Test func listOutOfSequenceIsNotAMenu() {
        let screen = """
        1. Yes
        3. No
        """
        #expect(ApprovalPrompt.trailingMenu(in: screen) == nil)
    }

    @Test func plainPromptHasNoMenu() {
        let screen = """
        ⏺ Done. The tests pass.

        ╭────────────────────────╮
        │ >                      │
        ╰────────────────────────╯
          ? for shortcuts
        """
        #expect(ApprovalPrompt.trailingMenu(in: screen) == nil)
    }

    @Test func laterMenuReplacesEarlierList() throws {
        let screen = """
        Steps:
        1. Build
        2. Test
        Do you want to proceed?
        ❯ 1. Yes
          2. No
        """
        let prompt = try #require(ApprovalPrompt.parse(screen: screen))
        #expect(prompt.options.map(\.label) == ["Yes", "No"])
    }

    // MARK: Wrapped labels

    @Test func wrappedClaudeBroadeningYesIsNotAllowed() throws {
        // A narrow pane breaks "auto-accept" onto the second line of the row.
        let screen = """
         Would you like to proceed?

         ❯ 1. Yes, clear context and
              auto-accept edits (shift+tab)
           2. Yes, and manually approve
              edits
           3. No, keep planning
        """
        let prompt = try #require(ApprovalPrompt.parse(screen: screen))
        #expect(prompt.options[0].label == "Yes, clear context and auto-accept edits (shift+tab)")
        #expect(prompt.allow == .character("2"))
    }

    @Test func wrappedClaudeMenuWithOnlyBroadeningYesHasNoAllow() {
        let screen = """
        │ ❯ 1. Yes, clear context and                │
        │      auto-accept edits (shift+tab)         │
        │   2. No, keep planning                     │
        """
        #expect(ApprovalPrompt.parse(screen: screen) == nil)
    }

    @Test func wrappedCodexShortcutIsFoundOnTheLastLine() throws {
        let screen = """
          Would you like to run the following command?

        › 1. Yes, proceed
             (y)
          2. Yes, and don't ask again for
             this command in this session (a)
          3. No, and tell Codex what to do
             differently (esc)

          Press enter to confirm or esc to cancel
        """
        let prompt = try #require(ApprovalPrompt.parse(screen: screen))
        #expect(prompt.allow == .character("y"))
        #expect(prompt.options[1].shortcut == "a")
        #expect(prompt.options[1].label == "Yes, and don't ask again for this command in this session")
        #expect(prompt.options[2].label == "No, and tell Codex what to do differently")
    }

    @Test func wordHardWrappedMidPhraseStillBroadens() {
        let screen = """
        ❯ 1. Yes, and auto-
             accept edits
          2. No
        """
        #expect(ApprovalPrompt.parse(screen: screen) == nil)
    }

    @Test func textBetweenRowsThatCannotBeAttributedRefusesAllow() {
        let screen = """
        ❯ 1. Yes

             and don't ask again
          2. No
        """
        #expect(ApprovalPrompt.parse(screen: screen) == nil)
        #expect(ApprovalPrompt.trailingMenu(in: screen)?.count == 2)
    }

    // MARK: Live menus need a cursor

    @Test func numberedListInTheAgentsMessageIsNotAMenu() {
        let screen = """
        ⏺ Next steps you could take:
          1. Yes, ship it as is
          2. No, add more tests first

        ╭────────────────────────╮
        │ >                      │
        ╰────────────────────────╯
          ? for shortcuts
        """
        #expect(ApprovalPrompt.trailingMenu(in: screen) == nil)
        #expect(ApprovalPrompt.parse(screen: screen) == nil)
    }

    @Test func numberedListAboveCodexComposerIsNotAMenu() {
        let screen = """
        • Two options:
          1. Keep the cache
          2. Drop it

        › Ask Codex to do anything
        """
        #expect(ApprovalPrompt.trailingMenu(in: screen) == nil)
    }

    @Test func realMenusAreStillLive() throws {
        #expect(ApprovalPrompt.trailingMenu(in: Self.claudeBash)?.count == 3)
        #expect(ApprovalPrompt.trailingMenu(in: Self.codexCommand)?.count == 3)
        let prompt = try #require(ApprovalPrompt.parse(screen: Self.claudeBash))
        #expect(prompt.options.map(\.isFocused) == [true, false, false])
    }

    @Test func approvalWithoutACursorIsNotAllowed() {
        let screen = """
        Do you want to proceed?
          1. Yes
          2. No
        """
        #expect(ApprovalPrompt.parse(screen: screen) == nil)
    }
}
