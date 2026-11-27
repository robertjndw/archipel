import ACPKit
import Foundation

extension ToolKind {
    var symbolName: String {
        switch self {
        case .read: "doc.text"
        case .edit: "pencil"
        case .delete: "trash"
        case .move: "arrow.right.doc.on.clipboard"
        case .search: "magnifyingglass"
        case .execute: "terminal"
        case .think: "brain"
        case .fetch: "globe"
        case .switchMode: "checklist"
        case .other: "wrench.and.screwdriver"
        }
    }

    /// What the agent is asking for, to follow its name: "Claude Code wants to edit a file".
    var permissionPhrase: String {
        switch self {
        case .read: "wants to read a file"
        case .edit: "wants to edit a file"
        case .delete: "wants to delete a file"
        case .move: "wants to move a file"
        case .search: "wants to search"
        case .execute: "wants to run a command"
        case .fetch: "wants to fetch from the web"
        case .switchMode: "has a plan ready"
        case .think, .other: "wants to use a tool"
        }
    }

    fileprivate var fallbackTitle: String {
        switch self {
        case .read: "Read"
        case .edit: "Edit"
        case .delete: "Delete"
        case .move: "Move"
        case .search: "Search"
        case .execute: "Run Command"
        case .think: "Think"
        case .fetch: "Fetch"
        case .switchMode: "Plan"
        case .other: "Tool"
        }
    }
}

extension ToolCallStatus {
    /// For VoiceOver, after the title: "Read README.md, completed".
    var spokenName: String {
        switch self {
        case .pending: "waiting"
        case .inProgress: "running"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "canceled"
        }
    }
}

/// A proposed or applied edit of one file.
struct ToolCallDiff: Equatable, Identifiable {
    var path: String
    var oldText: String?
    var newText: String

    var id: String { path }
    var fileName: String { (path as NSString).lastPathComponent }
}

extension ToolCall {
    /// The first line of the agent's title. Some titles are whole commands with line breaks.
    ///
    /// OpenCode titles a call with the bare tool name ("read") and only says what it touches in
    /// the locations or the raw input, so such a title is rebuilt from those.
    func displayTitle(relativeTo workingDirectory: String? = nil) -> String {
        let firstLine = title.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        // A lone lowercase identifier is a tool's name, not a description of the call.
        let isBareToolName = !firstLine.isEmpty && firstLine.allSatisfy { $0.isLowercase || $0 == "_" }
        guard firstLine.isEmpty || isBareToolName else {
            // "Read /abs/path/file.swift". A command keeps its text: its arguments are what runs.
            guard kind != .execute, let workingDirectory else { return firstLine }
            return firstLine.split(separator: " ", omittingEmptySubsequences: false)
                .map { $0.hasPrefix("/") ? displayPath(String($0), relativeTo: workingDirectory) : String($0) }
                .joined(separator: " ")
        }
        if kind == .execute, let line = command?.split(whereSeparator: \.isNewline).first {
            return String(line).trimmingCharacters(in: .whitespaces)
        }
        if let path = locations.first?.path, !path.isEmpty {
            return "\(kind.fallbackTitle) \((path as NSString).lastPathComponent)"
        }
        return firstLine.isEmpty || kind != .other ? kind.fallbackTitle : firstLine
    }

    var diffs: [ToolCallDiff] {
        content.compactMap { item in
            if case let .diff(path, oldText, newText) = item {
                ToolCallDiff(path: path, oldText: oldText, newText: newText)
            } else {
                nil
            }
        }
    }

    /// The edited file's name when the title does not already say it. Codex titles an edit
    /// "Edit file" and leaves the path to the diff.
    var diffFileNameMissingFromTitle: String? {
        guard let name = diffs.first?.fileName, !name.isEmpty, !title.contains(name) else { return nil }
        return name
    }

    /// The shell command, when the raw input has one. Claude sends a string, Codex an argument
    /// list whose last element is the script.
    var command: String? {
        guard let value = rawInput?["command"] else { return nil }
        if let text = value.stringValue { return text.isEmpty ? nil : text }
        if let arguments = value.arrayValue?.compactMap(\.stringValue), !arguments.isEmpty {
            if arguments.count == 3, arguments[1].hasPrefix("-"), arguments[1].contains("c") { return arguments[2] }
            return arguments.joined(separator: " ")
        }
        return nil
    }

    /// The text blocks of the content, in order.
    var textContent: [String] {
        content.compactMap { item in
            if case let .content(.text(text)) = item, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text
            } else {
                nil
            }
        }
    }

    /// Whether expanding the row would show anything.
    var hasDetails: Bool {
        !locations.isEmpty || !textContent.isEmpty || !diffs.isEmpty
            || !(terminalOutput ?? "").isEmpty || (terminalExitCode ?? 0) != 0 || commandDiffersFromTitle
    }

    /// The places an opened row lists: each once, and only the first few, since a search can
    /// turn up hundreds and the first ones say where it looked. `more` counts the ones left out.
    /// Find reads the same list, so it never steps to a place that is not on screen.
    var listedLocations: (shown: [ToolCallLocation], more: Int) {
        let unique = locations.reduce(into: [ToolCallLocation]()) { result, location in
            if !result.contains(location) { result.append(location) }
        }
        let shown = Array(unique.prefix(6))
        return (shown, unique.count - shown.count)
    }

    var commandDiffersFromTitle: Bool {
        guard let command else { return false }
        return command != title
    }

    func accessibilityLabel(relativeTo workingDirectory: String? = nil) -> String {
        "\(displayTitle(relativeTo: workingDirectory)), \(isRunningInBackground ? "running in the background" : status.spokenName)"
    }

    /// A subagent has a symbol of its own. Claude files the call under thinking, which would
    /// make it look like a thought.
    var symbolName: String {
        startsSubagent ? "arrow.triangle.branch" : kind.symbolName
    }

    /// The call, or what it left in the background, is not over yet.
    var isStillWorking: Bool {
        !status.isFinished || isRunningInBackground
    }

    /// One line on what a permission request is about: the command, or the file.
    func permissionSummary(relativeTo workingDirectory: String? = nil) -> String? {
        if kind == .switchMode { return nil }
        if let command { return command.split(whereSeparator: \.isNewline).first.map(String.init) }
        if let path = diffs.first?.path ?? locations.first?.path {
            return displayPath(path, relativeTo: workingDirectory ?? "")
        }
        return displayTitle(relativeTo: workingDirectory)
    }
}

extension ToolCallLocation {
    var url: URL { URL(fileURLWithPath: path) }

    /// "LoginViewModel.swift:18".
    var displayName: String {
        let name = (path as NSString).lastPathComponent
        return line.map { "\(name):\($0)" } ?? name
    }

    /// "Sources/Login/LoginViewModel.swift:18", the path as `displayPath` shows it.
    func displayLabel(relativeTo workingDirectory: String?) -> String {
        let shown = displayPath(path, relativeTo: workingDirectory ?? "")
        return line.map { "\(shown):\($0)" } ?? shown
    }
}
