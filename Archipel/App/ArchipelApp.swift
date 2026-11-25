import ArchipelCore
import SwiftUI
import TipKit

@main
struct ArchipelApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = ArchipelApp.makeModel()
    @State private var palette = CommandPaletteModel()
    @State private var switcher = TabSwitcherModel()
    @State private var updater = Updater()
    @State private var isAddingProject = false

    init() {
        SidebarTips.configure()
    }

    /// Xcode's preview host launches the whole app before it shows a preview. The real model would
    /// load the Debug workspace, start Ghostty and take over the Debug build's hook socket from a
    /// running instance, so the host gets an inert one.
    private static func makeModel() -> AppModel {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return AppModel(preview: Workspace())
        }
        #endif
        return AppModel()
    }

    var body: some Scene {
        // Here and not when the main window appears: the app can be launched without that window,
        // and quitting must still ask about unsaved work and save the workspace.
        let _ = delegate.model = model
        Window("Archipel", id: AppModel.mainWindowID) {
            RootView(isAddingProject: $isAddingProject)
                .environment(model)
                .environment(palette)
                .environment(switcher)
                .frame(minWidth: RootView.minimumWindowWidth, minHeight: 420)
                .onAppear {
                    model.applyAppearance()
                    // Reading the system's symbol list takes a few dozen milliseconds, which would
                    // otherwise land on the main thread the first time an island editor opens.
                    Task.detached(priority: .utility) { _ = SymbolCatalog.shared }
                }
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Nothing of the model is read here; see AppCommands.
            AppCommands(model: model, palette: palette, switcher: switcher, updater: updater, isAddingProject: $isAddingProject)
        }
        MenuBarExtra(isInserted: Bindable(model.settings).showsMenuBarExtra) {
            MenuBarExtraContent()
                .environment(model)
        } label: {
            MenuBarExtraLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
        Settings {
            SettingsView()
                .environment(model)
                .environment(updater)
        }
    }
}

extension AppModel {
    func applyAppearance() {
        NSApp.appearance = switch settings.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if !model.documents.dirtyURLs.isEmpty {
            // Named, because a file with edits can outlive its tab and would otherwise be a count
            // with nothing in the window to match it to.
            let names = model.documents.dirtyURLs.map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let alert = NSAlert()
            if names.count == 1 {
                alert.messageText = "Do you want to save the changes you made to \(names[0])?"
                alert.informativeText = "Your changes will be lost if you don't save them."
            } else {
                alert.messageText = "You have \(names.count) files with unsaved changes."
                alert.informativeText = "\(Self.listing(names)). Your changes will be lost if you don't save them."
            }
            alert.addButton(withTitle: "Save All")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Discard Changes").hasDestructiveAction = true
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard model.saveAllDocuments() else { return .terminateCancel }
            case .alertSecondButtonReturn:
                return .terminateCancel
            default:
                break
            }
        }
        // The same sessions closing a tab asks about: an agent waiting for an answer or a dev server
        // in a shell is lost to a quit just like an agent in the middle of a turn.
        let busy = model.settings.confirmsQuitWhileWorking ? model.sessionsWithWorkInFlight : 0
        guard busy > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = busy == 1 ? "Quit Archipel while a session is busy?" : "Quit Archipel while \(busy) sessions are busy?"
        alert.informativeText = "Agents that are working or waiting for you will be stopped, and so will commands running in a terminal. Agent conversations are kept and resume the next time you open the session."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// The first few names, then how many more there are, so the alert stays a readable size.
    static func listing(_ names: [String], limit: Int = 3) -> String {
        let shown = names.prefix(limit)
        let rest = names.count - shown.count
        if rest > 0 { return shown.joined(separator: ", ") + " and \(rest) more" }
        guard let last = shown.last, shown.count > 1 else { return shown.first ?? "" }
        return shown.dropLast().joined(separator: ", ") + " and " + last
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
