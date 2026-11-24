import ACPKit
@testable import ChatUI
import Foundation
import Synchronization
import Testing

@Suite
struct MentionTokenTests {
    private func token(_ draft: String, caret: Int? = nil) -> MentionToken? {
        FileMentions.token(in: draft, selection: NSRange(location: caret ?? (draft as NSString).length, length: 0))
    }

    @Test func anAtStartsAMentionAtTheStartOrAfterWhitespace() {
        #expect(token("@") == MentionToken(range: NSRange(location: 0, length: 1), query: ""))
        #expect(token("look at @Chat") == MentionToken(range: NSRange(location: 8, length: 5), query: "Chat"))
        #expect(token("first line\n@read") == MentionToken(range: NSRange(location: 11, length: 5), query: "read"))
        #expect(token("\t@a")?.query == "a")
    }

    @Test func anAddressIsNoMention() {
        #expect(token("mail a@b.c") == nil)
        #expect(token("a@") == nil)
        #expect(token("no mention here") == nil)
        #expect(token("") == nil)
    }

    @Test func theQueryEndsAtWhitespace() {
        #expect(token("@foo ") == nil)
        #expect(token("@foo bar") == nil)
        #expect(token("@foo\n") == nil)
    }

    @Test func theQueryIsWhatStandsBeforeTheCursorAndTheRangeTheWholeWord() {
        // The cursor moved back into "@foobar": what is behind it belongs to the same mention.
        #expect(token("see @foobar now", caret: 8) == MentionToken(range: NSRange(location: 4, length: 7), query: "foo"))
        #expect(token("see @foobar now", caret: 5) == MentionToken(range: NSRange(location: 4, length: 7), query: ""))
        // Before the @ the cursor is in no mention.
        #expect(token("see @foobar now", caret: 4) == nil)
    }

    @Test func anAtInsideTheWordIsPartOfTheQuery() {
        #expect(token("use @icon@2x")?.query == "icon@2x")
        #expect(token("@@")?.query == "@")
    }

    @Test func aSelectionIsNotAMentionBeingTyped() {
        #expect(FileMentions.token(in: "@foo", selection: NSRange(location: 1, length: 3)) == nil)
        #expect(FileMentions.token(in: "@foo", selection: NSRange(location: 9, length: 0)) == nil)
        #expect(FileMentions.token(in: "@foo", selection: NSRange(location: NSNotFound, length: 0)) == nil)
    }

    @Test func rangesCountTheWayTheTextViewDoes() {
        // The emoji is two UTF-16 units and one character.
        #expect(token("😀 @a") == MentionToken(range: NSRange(location: 3, length: 2), query: "a"))
        #expect(token("@日本")?.query == "日本")
    }

    @Test func aWallOfTextWithoutASpaceIsNotSearchedToItsStart() {
        #expect(token("@" + String(repeating: "x", count: 150))?.query.count == 150)
        #expect(token("@" + String(repeating: "x", count: 5_000)) == nil)
    }

    @Test func choosingAFilePutsItsNameWhereTheMentionWas() throws {
        let file = FileMention(path: "Sources/ChatUI/ChatView.swift")
        let draft = "look at @Chat"
        let edit = FileMentions.edit(choosing: file, for: try #require(token(draft)), in: draft)
        #expect(edit.range == NSRange(location: 8, length: 5))
        // A space behind it, to type on.
        #expect(edit.text == "ChatView.swift ")
        let result = (draft as NSString).replacingCharacters(in: edit.range, with: edit.text)
        #expect(result == "look at ChatView.swift ")
        // The name is no mention, so the list closes.
        #expect(token(result) == nil)
    }

    @Test func aMentionInTheMiddleOfASentenceKeepsItsOneSpace() throws {
        let file = FileMention(path: "Sources/ChatUI/ChatView.swift")
        let draft = "compare @Cha with the old one"
        let edit = FileMentions.edit(choosing: file, for: try #require(token(draft, caret: 12)), in: draft)
        #expect((draft as NSString).replacingCharacters(in: edit.range, with: edit.text) == "compare ChatView.swift with the old one")
    }

    @Test func aFolderReadsAsOne() throws {
        let folder = FileMention(path: "Sources/ChatUI/Views", isDirectory: true)
        let edit = FileMentions.edit(choosing: folder, for: try #require(token("@vi")), in: "@vi")
        #expect(edit.text == "Views/ ")
    }

    @Test func aNameTheWorktreeHasTwiceIsWrittenWithItsPath() {
        let candidates = FileMentions.candidates(fromFiles: [
            "Package.swift", "Packages/Kit/Package.swift", "Packages/Kit/Sources/Views/Row.swift", "README.md", "Sources/Views/List.swift",
        ])
        func text(_ id: String) -> String? {
            candidates.first { $0.id == id }.map(FileMentions.inlineText(for:))
        }
        // "make Package.swift match Package.swift" would say nothing.
        #expect(text("Package.swift") == "Package.swift")
        #expect(candidates.first { $0.id == "Package.swift" }?.isNameShared == true)
        #expect(text("Packages/Kit/Package.swift") == "Packages/Kit/Package.swift")
        // A name there is once stays short: the attachment carries the path.
        #expect(text("README.md") == "README.md")
        #expect(text("Sources/Views/List.swift") == "List.swift")
        // Folders count among themselves.
        #expect(text("Sources/Views/") == "Sources/Views/")
        #expect(text("Packages/Kit/") == "Kit/")
    }

    @Test func attachmentsThatShareANameShowTheirFolder() {
        let root = URL(filePath: "/repo/Package.swift")
        let nested = URL(filePath: "/repo/Packages/Kit/Package.swift")
        let other = URL(filePath: "/repo/README.md")
        let all = [root, nested, other]
        #expect(AttachmentChip.Item.name(of: root, among: all) == "repo/Package.swift")
        #expect(AttachmentChip.Item.name(of: nested, among: all) == "Kit/Package.swift")
        #expect(AttachmentChip.Item.name(of: other, among: all) == "README.md")
        #expect(AttachmentChip.Item.name(of: root, among: [root]) == "Package.swift")
        #expect(AttachmentChip.Item(url: nested, among: all).symbol == AttachmentChip.Item(url: nested).symbol)
    }
}

@Suite
struct FileMentionCandidateTests {
    @Test func nameAndFolderComeFromThePath() {
        let file = FileMention(path: "Sources/ChatUI/ChatView.swift")
        #expect(file.name == "ChatView.swift")
        #expect(file.folder == "Sources/ChatUI")
        #expect(file.id == "Sources/ChatUI/ChatView.swift")
        let top = FileMention(path: "README.md")
        #expect(top.name == "README.md")
        #expect(top.folder == "")
        let folder = FileMention(path: "Sources/ChatUI", isDirectory: true)
        #expect(folder.name == "ChatUI")
        #expect(folder.id == "Sources/ChatUI/")
    }

    @Test func urlsKeepFoldersApartFromFiles() {
        let root = URL(filePath: "/repo", directoryHint: .isDirectory)
        #expect(FileMention(path: "a b/c.swift").url(in: root).path(percentEncoded: false) == "/repo/a b/c.swift")
        let folder = FileMention(path: "Sources", isDirectory: true).url(in: root)
        #expect(folder.hasDirectoryPath)
        #expect(FileMentions.id(of: folder, in: root) == "Sources/")
    }

    @Test func everyFolderHoldingAFileCanBeMentionedToo() {
        let candidates = FileMentions.candidates(fromFiles: [
            "README.md",
            "Sources/App/Main.swift",
            "Sources/App/Views/List.swift",
            "Sources/App/Views/Row.swift",
            "Tests/AppTests.swift",
        ])
        // The top of the worktree first, then by path.
        #expect(candidates.map(\.id) == [
            "README.md", "Sources/", "Tests/",
            "Sources/App/", "Tests/AppTests.swift",
            "Sources/App/Main.swift", "Sources/App/Views/",
            "Sources/App/Views/List.swift", "Sources/App/Views/Row.swift",
        ])
    }

    @Test func whatIsHiddenComesAfterEverythingElse() {
        let candidates = FileMentions.candidates(fromFiles: [
            ".github/workflows/ci.yml", ".gitignore", "README.md", "Sources/.keep", "Sources/a.b.swift",
        ])
        #expect(candidates.map(\.id) == [
            "README.md", "Sources/", "Sources/a.b.swift",
            ".github/", ".gitignore", ".github/workflows/", "Sources/.keep", ".github/workflows/ci.yml",
        ])
        // Still found by name.
        #expect(FileMentions.rank(candidates, query: "ci")?.first?.id == ".github/workflows/ci.yml")
    }

    @Test func aNestedRepositoryIsAFolder() {
        let candidates = FileMentions.candidates(fromFiles: ["a.txt", "vendor/lib/", "vendor/lib/"])
        #expect(candidates.map(\.id) == ["a.txt", "vendor/", "vendor/lib/"])
    }

    @Test func upperAndLowerCaseAreListedTogether() {
        let candidates = FileMentions.candidates(fromFiles: [
            "Assets/icon.png", "Makefile", "README.md", "Sources/a.swift", "Tests/b.swift", "docs/guide.md", "file with spaces.txt", "notes.txt",
        ])
        #expect(candidates.prefix(8).map(\.id) == [
            "Assets/", "docs/", "file with spaces.txt", "Makefile", "notes.txt", "README.md", "Sources/", "Tests/",
        ])
        // Names that differ in case alone still have one order.
        #expect(FileMentions.candidates(fromFiles: ["b", "readme", "README", "a"]).map(\.id) == ["a", "b", "README", "readme"])
    }

    @Test func submodulesAreReadFromGitmodules() {
        let text = """
        [submodule "vendor/sub"]
        \tpath = vendor/sub
        \turl = https://example.com/sub.git
        [submodule "other"]
            path=third party/other
            branch = main
        """
        #expect(FileMentions.submodulePaths(inGitmodules: text) == ["vendor/sub", "third party/other"])
        #expect(FileMentions.submodulePaths(inGitmodules: "").isEmpty)
    }

    @Test func aSubmoduleInTheListingBecomesAFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mentions-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "[submodule \"vendor/sub\"]\n\tpath = vendor/sub\n".write(to: folder.appending(path: ".gitmodules"), atomically: true, encoding: .utf8)
        // git lists a submodule without the slash a folder has.
        var paths = [".gitmodules", "a.txt", "vendor/sub", "vendor/subway.txt"]
        WorktreeFileIndex.markSubmodules(in: &paths, root: folder)
        #expect(paths == [".gitmodules", "a.txt", "vendor/sub/", "vendor/subway.txt"])
        #expect(FileMentions.candidates(fromFiles: paths).first { $0.path == "vendor/sub" }?.isDirectory == true)
        // Without a .gitmodules in the listing the file is not even looked for.
        var plain = ["a.txt", "vendor/sub"]
        WorktreeFileIndex.markSubmodules(in: &plain, root: folder)
        #expect(plain == ["a.txt", "vendor/sub"])
    }

    @Test func aChosenEntryThatIsAFolderOnDiskIsMentionedAsOne() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "mentions-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "vendor/sub"), withIntermediateDirectories: true)
        try Data().write(to: root.appending(path: "a.txt"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "linked"), withDestinationURL: root.appending(path: "vendor"))
        // A submodule and a link to a folder both come out of git's listing looking like files.
        let submodule = FileMentions.resolved(FileMention(path: "vendor/sub"), in: root)
        #expect(submodule.isDirectory)
        #expect(FileMentions.inlineText(for: submodule) == "sub/")
        #expect(submodule.url(in: root).hasDirectoryPath)
        #expect(FileMentions.resolved(FileMention(path: "linked"), in: root).isDirectory)
        #expect(!FileMentions.resolved(FileMention(path: "a.txt"), in: root).isDirectory)
        #expect(!FileMentions.resolved(FileMention(path: "gone.txt"), in: root).isDirectory)
    }

    @Test func idsOfAttachmentsAreRelativeToTheWorktree() {
        let root = URL(filePath: "/repo/project", directoryHint: .isDirectory)
        #expect(FileMentions.id(of: URL(filePath: "/repo/project/Sources/a.swift"), in: root) == "Sources/a.swift")
        #expect(FileMentions.id(of: URL(filePath: "/repo/project/Sources/../b.swift"), in: root) == "b.swift")
        #expect(FileMentions.id(of: URL(filePath: "/repo/project-two/a.swift"), in: root) == nil)
        #expect(FileMentions.id(of: URL(filePath: "/tmp/Pasted Image.png"), in: root) == nil)
        #expect(FileMentions.id(of: root, in: root) == nil)
    }

    @Test func recentFilesAreTheOnesSentNewestPromptFirst() {
        let root = URL(filePath: "/repo", directoryHint: .isDirectory)
        func link(_ path: String) -> ContentBlock {
            .resourceLink(ResourceLink(uri: URL(filePath: path).absoluteString, name: (path as NSString).lastPathComponent))
        }
        var transcript = ChatTranscript()
        transcript.appendUserPrompt([.text("one"), link("/repo/a.swift"), link("/repo/Sources/b.swift")])
        transcript.endTurn(nil)
        transcript.appendUserPrompt([
            .text("two"), link("/repo/Sources/b.swift"), link("/elsewhere/c.swift"),
            .image(data: "", mimeType: "image/png", uri: URL(filePath: "/repo/shot.png").absoluteString),
        ])
        #expect(FileMentions.recentIDs(in: transcript.items, root: root) == ["Sources/b.swift", "shot.png", "a.swift"])
    }
}

@Suite
struct FileMentionRankingTests {
    private let candidates = FileMentions.candidates(fromFiles: [
        "Package.swift",
        "README.md",
        "Sources/ChatUI/ChatSession.swift",
        "Sources/ChatUI/ChatView.swift",
        "Sources/ChatUI/Views/ChatComposer.swift",
        "Sources/ChatUI/Views/CompletionList.swift",
        "Sources/ChatUI/Views/DiffCache.swift",
        "Sources/Legacy/Deep/Down/ChatView.swift",
        "Tests/ChatUITests/ChatViewTests.swift",
        "docs/chat-protocol.md",
    ])

    private func ranked(_ query: String, recent: [String] = [], limit: Int = 50) -> [String] {
        (FileMentions.rank(candidates, query: query, recent: recent, limit: limit) ?? []).map(\.id)
    }

    @Test func anEmptyQueryShowsTheTopOfTheWorktree() {
        #expect(ranked("", limit: 5) == ["docs/", "Package.swift", "README.md", "Sources/", "Tests/"])
    }

    @Test func recentlySentFilesLeadAnEmptyQuery() {
        let recent = ["Sources/ChatUI/Views/DiffCache.swift", "README.md", "gone.swift"]
        // A file that is no longer in the worktree is not offered.
        #expect(ranked("", recent: recent, limit: 4) == ["Sources/ChatUI/Views/DiffCache.swift", "README.md", "docs/", "Package.swift"])
        // Recency does not reorder what a query finds.
        #expect(ranked("readme", recent: recent).first == "README.md")
    }

    @Test func aFileIsStillTheTopMatchForItsOwnNameOnceItIsAttached() {
        // Nothing about the attachments reaches the ranking: a second "@ChatView.swift" writes
        // the same file's name again, and must not pick the next best file in its place.
        #expect(ranked("ChatView.swift").first == "Sources/ChatUI/ChatView.swift")
        #expect(ranked("", recent: ["README.md"], limit: 1) == ["README.md"])
    }

    @Test func aWordScatteredOverThePathIsNoMention() {
        let candidates = FileMentions.candidates(fromFiles: [
            "Sources/ChatUI/Views/ChatStateViews.swift",
            "Tests/ACPKitTests/Fixtures/opencode-update-available_commands_update.json",
            "Tests/ChatUITests/ChatSessionStoppingTests.swift",
            "Tests/ChatUITests/ChatSessionTests.swift",
        ])
        func found(_ query: String) -> [String] {
            (FileMentions.rank(candidates, query: query) ?? []).map(\.id)
        }
        // Each of these has its letters in order somewhere along one of the paths, which is all
        // the fuzzy match asks for. None is in a name in order or in a path in one piece, so a
        // prompt about code that ends in one still sends on Return.
        #expect(found("escaping").isEmpty)
        #expect(found("Sendable").isEmpty)
        #expect(found("testable").isEmpty)
        #expect(found("MainActor").isEmpty)
        // A word a file name does contain is a mention like any other.
        #expect(found("State") == ["Sources/ChatUI/Views/ChatStateViews.swift"])
        // An abbreviation of a name still finds it, and a folder's name what is under it.
        #expect(found("csv") == ["Sources/ChatUI/Views/ChatStateViews.swift"])
        #expect(found("stoptests") == ["Tests/ChatUITests/ChatSessionStoppingTests.swift"])
        #expect(Set(found("fixtures")) == ["Tests/ACPKitTests/Fixtures/", "Tests/ACPKitTests/Fixtures/opencode-update-available_commands_update.json"])
        // A path being typed narrows by folder, however loosely its parts are spelled.
        #expect(found("chatui/stop") == ["Tests/ChatUITests/ChatSessionStoppingTests.swift"])
        #expect(found("cut/stop") == ["Tests/ChatUITests/ChatSessionStoppingTests.swift"])
        // Names outside ASCII are left to the fuzzy match.
        let umlauts = FileMentions.candidates(fromFiles: ["Notizen/Übersicht.md"])
        #expect(FileMentions.rank(umlauts, query: "übersicht")?.map(\.id) == ["Notizen/Übersicht.md"])
    }

    @Test func theQueryHasToAppearInOrder() {
        #expect(ranked("zzz").isEmpty)
        #expect(ranked("cmpsr") == ["Sources/ChatUI/Views/ChatComposer.swift"])
        #expect(ranked("DIFFCACHE") == ["Sources/ChatUI/Views/DiffCache.swift"])
    }

    @Test func aMatchInTheNameBeatsOneInTheFolders() {
        // "views" is a folder of the first two and the start of no file name.
        let views = ranked("views")
        #expect(views.first == "Sources/ChatUI/Views/")
        // Every file under ChatUI matches "chat" in its path; the ones named Chat… come first.
        let chat = ranked("chat")
        let named = chat.firstIndex(of: "Sources/ChatUI/ChatView.swift")!
        let inFolder = chat.firstIndex(of: "Sources/ChatUI/Views/DiffCache.swift")!
        #expect(named < inFolder)
    }

    @Test func theStartOfTheNameAndOfAWordBeatTheMiddle() {
        // "list" starts a word of CompletionList and is nowhere else a word.
        #expect(ranked("list").first == "Sources/ChatUI/Views/CompletionList.swift")
        let session = ranked("sess")
        #expect(session.first == "Sources/ChatUI/ChatSession.swift")
        // A name that starts with the query beats one that has it further in.
        let view = ranked("chatview")
        #expect(view.firstIndex(of: "Sources/ChatUI/ChatView.swift")! < view.firstIndex(of: "Tests/ChatUITests/ChatViewTests.swift")!)
    }

    @Test func theShorterPathWinsBetweenEqualNames() {
        let view = ranked("chatview.swift")
        #expect(view.prefix(2) == ["Sources/ChatUI/ChatView.swift", "Sources/Legacy/Deep/Down/ChatView.swift"])
    }

    @Test func aFileComesBeforeAFolderThatMatchesAsWell() {
        // The ChatUI folder starts with "chat" and is shorter than any file in it.
        let chat = ranked("chat")
        #expect(chat.first?.hasSuffix("/") == false)
        #expect(chat.contains("Sources/ChatUI/"))
        // An exact folder name still leads.
        #expect(ranked("chatui").first == "Sources/ChatUI/")
    }

    @Test func aPathNarrowsToAFolder() {
        #expect(Set(ranked("views/")) == [
            "Sources/ChatUI/Views/ChatComposer.swift", "Sources/ChatUI/Views/CompletionList.swift", "Sources/ChatUI/Views/DiffCache.swift",
        ])
    }

    @Test func theListIsCapped() {
        #expect(ranked("s", limit: 3).count == 3)
        #expect(ranked("s", limit: 0).isEmpty)
    }

    @Test func aCancelledSearchHasNoAnswer() {
        #expect(FileMentions.rank(candidates, query: "chat", isCancelled: { true }) == nil)
    }

    @Test func aLargeRepositoryIsRankedInPiecesWithTheSameResult() {
        // More than one piece, with the best match in the last one.
        var paths = (0..<12_000).map { "Sources/Module\($0 / 100)/File\($0).swift" }
        paths.append("Sources/Zebra/Needle.swift")
        let large = FileMentions.candidates(fromFiles: paths)
        let found = FileMentions.rank(large, query: "needle", limit: 5) ?? []
        #expect(found.map(\.id) == ["Sources/Zebra/Needle.swift"])
        #expect(FileMentions.rank(large, query: "file119", limit: 3)?.first?.id == "Sources/Module1/File119.swift")
    }
}

@Suite
struct CompletionSelectionTests {
    @Test func theSelectionStaysInAListThatGotShorter() {
        #expect(CompletionSelection.index(0, count: 3) == 0)
        #expect(CompletionSelection.index(5, count: 3) == 2)
        #expect(CompletionSelection.index(2, count: 0) == 0)
    }

    @Test func theArrowsWrapAround() {
        #expect(CompletionSelection.index(0, movedBy: 1, count: 3) == 1)
        #expect(CompletionSelection.index(2, movedBy: 1, count: 3) == 0)
        #expect(CompletionSelection.index(0, movedBy: -1, count: 3) == 2)
        // From a selection the shorter list no longer has.
        #expect(CompletionSelection.index(9, movedBy: 1, count: 3) == 0)
        #expect(CompletionSelection.index(0, movedBy: 1, count: 0) == 0)
    }

    @Test func rowsNameFilesByNameAndFolder() {
        let file = CompletionRow(file: FileMention(path: "Sources/ChatUI/ChatView.swift"))
        #expect(file.title == "ChatView.swift")
        #expect(file.detail == "Sources/ChatUI")
        #expect(file.symbol == "swift")
        #expect(file.accessibilityLabel == "ChatView.swift, file in Sources/ChatUI")
        let folder = CompletionRow(file: FileMention(path: "Sources", isDirectory: true))
        #expect(folder.symbol == "folder")
        #expect(folder.accessibilityLabel == "Sources, folder")
        let command = CompletionRow(command: AvailableCommand(name: "/review", description: "Review the changes"))
        #expect(command.title == "/review")
        #expect(command.symbol == nil)
        #expect(command.accessibilityLabel == "review, Review the changes")
    }

    @Test func voiceOverIsToldThatTheListOpenedAndWhichRowItIsOn() throws {
        let rows = ["Sources/ChatUI/ChatView.swift", "Sources/ChatUI/ChatViewActions.swift", "README.md"].map {
            CompletionRow(file: FileMention(path: $0))
        }
        let first = try #require(CompletionList.Announcement(kind: .files, rows: rows, selection: 0))
        // The kind once, when the list opens over the text being typed.
        #expect(first.text(isOpening: true) == "Files: ChatView.swift, file in Sources/ChatUI, 1 of 3")
        // After that only the row: the arrows no longer move the cursor, and Return will choose it.
        let third = try #require(CompletionList.Announcement(kind: .files, rows: rows, selection: 2))
        #expect(third.text(isOpening: false) == "README.md, file, 3 of 3")
        #expect(first != third)
        // Another keystroke that leaves the same row on top of as many says nothing again.
        #expect(first == CompletionList.Announcement(kind: .files, rows: rows, selection: 0))
        let commands = [CompletionRow(command: AvailableCommand(name: "review", description: "Review the changes"))]
        #expect(CompletionList.Announcement(kind: .commands, rows: commands, selection: 0)?.text(isOpening: true) == "Commands: review, Review the changes, 1 of 1")
        #expect(CompletionList.Announcement(kind: .files, rows: [], selection: 0) == nil)
    }

    @MainActor @Test func aMentionedFolderKeepsItsSymbolFromTheComposerIntoTheSentMessage() {
        let root = URL(filePath: "/work", directoryHint: .isDirectory)
        let folder = FileMention(path: "Sources/Views", isDirectory: true).url(in: root)
        let file = FileMention(path: "Sources/Views/ChatView.swift").url(in: root)
        // In the composer, from the URL.
        #expect(AttachmentChip.Item(url: folder) == AttachmentChip.Item(name: "Views", symbol: "folder"))
        #expect(AttachmentChip.Item(url: file).symbol == "swift")
        // In the transcript, from the link the prompt went out with.
        #expect(AttachmentChip.Item(block: ChatSession.linkBlock(for: folder)) == AttachmentChip.Item(name: "Views", symbol: "folder"))
        #expect(AttachmentChip.Item(block: ChatSession.linkBlock(for: file))?.symbol == "swift")
    }
}

@Suite(.timeLimit(.minutes(1)))
struct WorktreeFileIndexTests {
    private struct NotARepository: Error {}

    /// A lister that answers from a script and counts how often it was asked.
    private final class Listing: Sendable {
        private let state: Mutex<(files: [String], calls: Int)>

        init(_ files: [String]) {
            state = Mutex((files, 0))
        }

        var calls: Int { state.withLock { $0.calls } }

        func set(_ files: [String]) {
            state.withLock { $0.files = files }
        }

        var lister: WorktreeFileIndex.Lister {
            { _ in
                self.state.withLock {
                    $0.calls += 1
                    return $0.files
                }
            }
        }
    }

    private let root = URL(filePath: "/repo", directoryHint: .isDirectory)

    @Test func theFirstQuestionListsTheFilesAndLaterOnesReuseThem() async {
        let listing = Listing(["README.md", "Sources/Main.swift"])
        let index = WorktreeFileIndex(root: root, list: listing.lister, staleAfter: .seconds(3600))
        #expect(listing.calls == 0)
        #expect(await index.matches(query: "main").map(\.id) == ["Sources/Main.swift"])
        #expect(await index.matches(query: "").map(\.id) == ["README.md", "Sources/", "Sources/Main.swift"])
        #expect(await index.refreshIfStale() == false)
        #expect(listing.calls == 1)
    }

    @Test func aStaleListIsReadAgainAndSaysWhetherItChanged() async {
        let listing = Listing(["a.swift"])
        let index = WorktreeFileIndex(root: root, list: listing.lister, staleAfter: .zero)
        // The first listing is nothing to ask again for: nothing was shown before it.
        #expect(await index.refreshIfStale() == false)
        #expect(await index.refreshIfStale() == false)
        listing.set(["a.swift", "new.swift"])
        #expect(await index.refreshIfStale() == true)
        #expect(await index.matches(query: "new").map(\.id) == ["new.swift"])
        #expect(listing.calls == 3)
    }

    @Test func aFixedIndexNeverLooksAtTheDisk() async {
        let index = WorktreeFileIndex(root: root, files: ["Sources/Login/LoginView.swift", "README.md"])
        #expect(await index.matches(query: "loginview").first?.id == "Sources/Login/LoginView.swift")
        #expect(await index.refreshIfStale() == false)
    }

    @MainActor
    @Test func aSessionIndexesItsWorkingDirectoryThroughItsConfiguration() async throws {
        let listing = Listing(["Sources/a.swift"])
        var configuration = ChatSession.Configuration(
            agentName: "Fake Agent", workingDirectory: "/repo",
            clientInfo: Implementation(name: "archipel-tests", version: "1.0"),
            resolveLaunch: { _ in ChatLaunch(executable: URL(fileURLWithPath: "/usr/bin/true")) }
        )
        configuration.listFiles = listing.lister
        let session = ChatSession(configuration: configuration)
        let index = try #require(session.fileIndex)
        #expect(index.root.path(percentEncoded: false) == "/repo/")
        // Nothing is listed until an @ asks.
        #expect(listing.calls == 0)
        let found = try #require(await index.matches(query: "a.sw").first)
        #expect(listing.calls == 1)

        // Choosing the file attaches it the way a dropped file is attached.
        session.addAttachments([found.url(in: index.root)])
        #expect(session.attachments.map { $0.path(percentEncoded: false) } == ["/repo/Sources/a.swift"])
        #expect(FileMentions.id(of: session.attachments[0], in: index.root) == "Sources/a.swift")
    }

    @MainActor
    @Test func aPreviewSessionOffersItsSampleFiles() async throws {
        let index = try #require(ChatSession.preview(.empty).fileIndex)
        #expect(await index.matches(query: "loginvm").first?.id == "Sources/Login/LoginViewModel.swift")
    }

    @Test func aCancelledQuestionAnswersNothing() async {
        let index = WorktreeFileIndex(root: root, files: ["a.swift"])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await index.matches(query: "a")
        }
        #expect(await task.value.isEmpty)
    }

    @Test func aFolderThatIsNoRepositoryIsWalked() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mentions-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        for path in ["notes.txt", "src/main.c", "src/deep/util.c", ".git/config", "node_modules/pkg/index.js", ".build/debug/out.o", ".env"] {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let index = WorktreeFileIndex(root: folder, list: { _ in throw NotARepository() })
        // Hidden folders and build output are left out; a hidden file is a file like any other.
        #expect(await index.matches(query: "").map(\.id) == ["notes.txt", "src/", "src/deep/", "src/main.c", "src/deep/util.c", ".env"])
        #expect(WorktreeFileIndex.walk(folder, limit: 2).count == 2)
    }

    @Test func aWalkThatHitsItsLimitKeepsWhatIsNearTheTop() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mentions-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        var paths = ["app.py", "zebra.txt", "src/main.py", "src/util.py", "src/core/engine.py"]
        // One folder of downloaded packages, deeper and larger than everything else together.
        paths += (0..<40).map { "venv/lib/site-packages/pkg\($0).py" }
        // And one beside the sources that alone is over the limit.
        paths += (0..<40).map { "data/sample\($0).csv" }
        for path in paths {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let walked = WorktreeFileIndex.walk(folder, limit: 12)
        #expect(walked.count == 12)
        // The project's own files are all there: the cut took the big folder of their level
        // last, and never got as deep as the packages.
        #expect(Set(walked).isSuperset(of: ["app.py", "zebra.txt", "src/main.py", "src/util.py"]))
        #expect(walked.filter { $0.hasPrefix("data/") }.count == 8)
        #expect(!walked.contains { $0.hasPrefix("venv/") })
        // The same cut every time.
        #expect(WorktreeFileIndex.walk(folder, limit: 12) == walked)
    }
}
