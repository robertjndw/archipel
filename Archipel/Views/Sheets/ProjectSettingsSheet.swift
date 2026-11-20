import AppKit
import ArchipelCore
import SwiftUI
import UniformTypeIdentifiers

/// Edits a project's identity, worktree defaults and scripts. Nothing is applied until Save.
struct ProjectSettingsSheet: View {
    private enum Page: String, CaseIterable, Identifiable {
        case general = "General"
        case worktrees = "Worktrees"
        case scripts = "Scripts"

        var id: Self { self }
    }

    private enum IconKind: Hashable { case automatic, symbol, image }

    /// Shown first in the symbol picker: symbols that suit software projects.
    static let suggestedSymbols = [
        "shippingbox", "terminal", "chevron.left.forwardslash.chevron.right", "curlybraces",
        "hammer", "wrench.and.screwdriver", "gearshape", "cpu",
        "server.rack", "externaldrive", "internaldrive", "network",
        "globe", "cloud", "antenna.radiowaves.left.and.right", "bolt",
        "flame", "leaf", "swift", "app.badge",
        "macwindow", "iphone", "safari", "doc.text",
        "book", "chart.bar", "cube", "puzzlepiece",
        "lock.shield", "testtube.2", "ladybug", "sparkles",
    ]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: Project

    @State private var page = Page.general
    @State private var name = ""
    @State private var icon = ProjectIcon.automatic
    @State private var tint: Tint?
    @State private var worktreesDirectory: URL?
    @State private var baseBranch: String?
    @State private var setup = ""
    @State private var run = ""
    @State private var branches: [String]?
    @State private var previewImage: NSImage?
    @State private var isPickingImage = false
    @State private var isPickingFolder = false
    @State private var didLoad = false
    @State private var confirmsDiscard = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Page", selection: $page) {
                ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            // Large draws as a capsule on macOS 26+, matching the app's other pill-shaped switchers.
            .controlSize(.large)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 16)
            // On a view of its own: of two file importers on the same view only the last one presents.
            .fileImporter(isPresented: $isPickingImage, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result { icon = .image(url) }
            }

            Form {
                switch page {
                case .general: generalSections
                case .worktrees: worktreeSections
                case .scripts: scriptSections
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 520, height: 600)
        .navigationTitle("\(project.name) Settings")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if hasChanges { confirmsDiscard = true } else { dismiss() }
                }
                .untinted()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(trimmedName.isEmpty)
            }
        }
        .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { worktreesDirectory = url }
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmsDiscard) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .task { await load() }
        .task(id: icon) { await refreshPreview() }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// False until `load()` has filled the fields, so the empty initial state never counts as an edit.
    private var hasChanges: Bool {
        didLoad && (
            trimmedName != project.name
                || icon != project.icon
                || tint != project.tint
                || worktreesDirectory != project.worktreesDirectory
                || baseBranch != project.baseBranch
                || setup != project.scripts.setup
                || run != project.scripts.run
        )
    }

    private var previewColor: Color {
        (tint ?? model.tint(of: project)).color
    }

    // MARK: General

    @ViewBuilder
    private var generalSections: some View {
        Section {
            HStack(spacing: 16) {
                ProjectIconTile(icon: icon, image: previewImage, name: trimmedName, color: previewColor, size: 56)
                TextField("Name", text: $name, prompt: Text("Project Name"))
                    .textFieldStyle(.plain)
                    .labelsHidden()
                    .font(.title2.weight(.semibold))
            }
            .padding(.vertical, 4)
        }

        Section {
            Picker("Icon", selection: iconKind) {
                Text("Automatic").tag(IconKind.automatic)
                Text("Symbol").tag(IconKind.symbol)
                Text("Custom Image").tag(IconKind.image)
            }
            switch icon {
            case .automatic:
                EmptyView()
            case .symbol(let current):
                SymbolPicker(
                    selection: Binding(get: { current }, set: { icon = .symbol($0) }),
                    suggestions: Self.suggestedSymbols,
                    tint: previewColor
                )
            case .image(let url):
                LabeledContent("Image") {
                    HStack {
                        Text(url.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { isPickingImage = true }
                    }
                }
            }
        } header: {
            Text("Icon")
        } footer: {
            Text("Automatic uses an icon found in the repository, such as its app icon, favicon or logo. Without one it uses the avatar of the repository's owner on GitHub, and otherwise the project's initial.")
        }

        Section {
            TintSwatchPicker(selection: $tint, automaticLabel: "Same as Island")
        } header: {
            Text("Color")
        } footer: {
            Text("Same as Island follows the color of the island this project is in.")
        }

        Section {
            LabeledContent("Repository") {
                Text(project.folderURL.abbreviatedPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Button("Show in Finder") { model.revealInFinder(project.folderURL) }
        }
    }

    private var iconKind: Binding<IconKind> {
        Binding {
            switch icon {
            case .automatic: .automatic
            case .symbol: .symbol
            case .image: .image
            }
        } set: { kind in
            switch kind {
            case .automatic:
                icon = .automatic
            case .symbol:
                if case .symbol = icon { return }
                icon = .symbol(Self.suggestedSymbols[0])
            case .image:
                if case .image = icon { return }
                isPickingImage = true
            }
        }
    }

    // MARK: Worktrees

    private var defaultFolder: URL {
        model.defaultWorktreesFolder(for: project)
    }

    @ViewBuilder
    private var worktreeSections: some View {
        Section {
            LabeledContent("Folder") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text((worktreesDirectory ?? defaultFolder).abbreviatedPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    if worktreesDirectory == nil {
                        Text("Default").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                Button("Choose…") { isPickingFolder = true }
                Button("Use Default") { worktreesDirectory = nil }
                    .disabled(worktreesDirectory == nil)
            }
        } header: {
            Text("Location")
        } footer: {
            Text("New worktrees are created in \(examplePath). The default folder is set in Archipel's settings.")
        }

        Section {
            if let branches {
                Picker("Base branch", selection: $baseBranch) {
                    Text("Automatic").tag(String?.none)
                    ForEach(baseBranchChoices(from: branches), id: \.self) { Text($0).tag(Optional($0)) }
                }
            } else {
                TextField("Base branch", text: baseBranchText, prompt: Text("Automatic"))
            }
        } header: {
            Text("New Branches")
        } footer: {
            Text("New branches start from this branch. Automatic uses the remote's default branch for new worktrees and the current branch when switching in place.")
        }
    }

    private var examplePath: String {
        var draft = project
        draft.worktreesDirectory = worktreesDirectory
        draft.name = trimmedName.isEmpty ? project.name : trimmedName
        return model.worktreePath(for: draft, branch: "feature/login").abbreviatedPath
    }

    /// Keeps a saved base branch selectable even when it no longer exists locally.
    private func baseBranchChoices(from branches: [String]) -> [String] {
        guard let baseBranch, !branches.contains(baseBranch) else { return branches }
        return [baseBranch] + branches
    }

    private var baseBranchText: Binding<String> {
        Binding {
            baseBranch ?? ""
        } set: {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            baseBranch = value.isEmpty ? nil : value
        }
    }

    // MARK: Scripts

    @ViewBuilder
    private var scriptSections: some View {
        Section {
            ScriptEditor(text: $setup)
        } header: {
            Text("Setup Script")
        } footer: {
            Text("Runs once in each new worktree, for example to install dependencies or copy .env from the main checkout.")
        }
        Section {
            ScriptEditor(text: $run)
        } header: {
            Text("Run Script")
        } footer: {
            // Run (⌘R) opens this page when there is nothing to run, so the empty state says why.
            if run.allSatisfy(\.isWhitespace) {
                Text("There's no run script yet, which is why Run (⌘R) opened this page. Add a command like npm run dev.")
            } else {
                Text("Started with Run (⌘R), for example a dev server. Running again restarts it.")
            }
        }
        Section {
            Text("""
            Scripts run with zsh in the worktree folder, as their own session tab. These variables are set:
            ARCHIPEL_WORKTREE_PATH: the worktree folder
            ARCHIPEL_ROOT_PATH: the project's main checkout
            ARCHIPEL_BRANCH: the worktree's branch, when it has one
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
    }

    // MARK: Loading and saving

    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        if model.projectSettingsShowsScripts { page = .scripts }
        name = project.name
        icon = project.icon
        tint = project.tint
        worktreesDirectory = project.worktreesDirectory
        baseBranch = project.baseBranch
        setup = project.scripts.setup
        run = project.scripts.run
        // Left nil without git, which shows the plain text field instead of the system's offer to install it.
        if model.isGitAvailable {
            branches = try? await model.git.localBranches(in: project.folderURL)
        }
    }

    private func refreshPreview() async {
        let image = await ProjectIconFinder.image(for: icon, in: project.folderURL)
        // A slower load for an earlier choice must not replace the current one.
        if !Task.isCancelled { previewImage = image }
    }

    private func save() {
        model.updateProject(project.id) {
            $0.name = trimmedName
            $0.icon = icon
            $0.tint = tint
            $0.worktreesDirectory = worktreesDirectory
            $0.baseBranch = baseBranch
            $0.scripts = ProjectScripts(setup: setup, run: run)
        }
        dismiss()
    }
}

/// A plain NSTextView, because SwiftUI's TextEditor follows the system's smart quotes and dashes
/// setting, which would silently turn `"$VAR"` and `--flag` into something no shell understands.
private struct ScriptEditor: View {
    @Binding var text: String

    var body: some View {
        ScriptTextView(text: $text)
            .frame(minHeight: 90, maxHeight: 180)
            .accessibilityLabel("Script")
    }
}

private struct ScriptTextView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.string = text
        textView.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

#if DEBUG
extension ProjectSettingsSheet {
    /// `load()` only ever switches to Scripts, so Worktrees has to start there to be previewed.
    fileprivate static func onWorktreesPage(_ project: Project) -> Self {
        var sheet = Self(project: project)
        sheet._page = State(initialValue: .worktrees)
        return sheet
    }
}

#Preview("General, symbol icon") {
    ProjectSettingsSheet(project: PreviewFixtures.appProject)
        .environment(AppModel.preview())
}

#Preview("General, automatic icon and tint") {
    ProjectSettingsSheet(project: PreviewFixtures.blogProject)
        .environment(AppModel.preview())
}

#Preview("Worktrees, default folder") {
    ProjectSettingsSheet.onWorktreesPage(PreviewFixtures.appProject)
        .environment(AppModel.preview())
}

#Preview("Worktrees, custom folder and base branch") {
    var project = PreviewFixtures.appProject
    project.worktreesDirectory = PreviewFixtures.root.appending(path: "orbit-worktrees", directoryHint: .isDirectory)
    project.baseBranch = "develop"
    return ProjectSettingsSheet.onWorktreesPage(project)
        .environment(AppModel.preview())
}

#Preview("Scripts, filled") {
    let model = AppModel.preview()
    model.projectSettingsShowsScripts = true
    return ProjectSettingsSheet(project: PreviewFixtures.appProject)
        .environment(model)
}

#Preview("Scripts, empty") {
    let model = AppModel.preview()
    model.projectSettingsShowsScripts = true
    return ProjectSettingsSheet(project: PreviewFixtures.blogProject)
        .environment(model)
}
#endif
