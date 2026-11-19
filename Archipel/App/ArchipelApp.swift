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
        Window("Archipel", id: AppModel.mainWindowID) {
            RootView(isAddingProject: $isAddingProject)
                .environment(model)
                .environment(palette)
                .environment(switcher)
                .frame(minWidth: RootView.minimumWindowWidth, minHeight: 420)
                .onAppear {
                    delegate.model = model
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
            let count = model.documents.dirtyURLs.count
            let alert = NSAlert()
            alert.messageText = count == 1 ? "You have a file with unsaved changes." : "You have \(count) files with unsaved changes."
            alert.informativeText = "Your changes will be lost if you don't save them."
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
        guard model.hasWorkingSessions, model.settings.confirmsQuitWhileWorking else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit Archipel while agents are working?"
        alert.informativeText = "Running agents will be stopped. Their conversations are kept and resume the next time you open the session."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutDown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
