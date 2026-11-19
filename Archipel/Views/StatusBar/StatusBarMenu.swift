import AppKit
import SwiftUI

/// What a right-click on the status bar offers, like the menu of the macOS menu bar: a checkmark
/// per item, then the way to Settings. The preview in Settings shows the same menu without it.
///
/// AppKit rather than `.contextMenu`, because SwiftUI gives no say over where the menu opens, and
/// at the bottom of the screen it can end up at the top (see `showMenu`). The menu is built at the
/// click, so the countdowns ticking underneath can't change it while it is open.
struct StatusBarMenuArea: NSViewRepresentable {
    let settings: AppSettings
    var openSettings: (() -> Void)?

    func makeNSView(context: Context) -> RightClickView {
        let view = RightClickView()
        view.settings = settings
        view.openSettings = openSettings
        return view
    }

    func updateNSView(_ view: RightClickView, context: Context) {
        view.settings = settings
        view.openSettings = openSettings
    }

    /// Lies over the whole strip but only takes right-clicks and control-clicks. Everything else,
    /// clicks, hovers and tooltips, falls through to the items underneath.
    final class RightClickView: NSView {
        var settings: AppSettings?
        var openSettings: (() -> Void)?
        private var target: MenuTarget?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isContextClick = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return isContextClick ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }
        override func mouseDown(with event: NSEvent) { showMenu(for: event) }

        private func showMenu(for event: NSEvent) {
            guard let settings else { return }
            let target = MenuTarget(settings: settings, openSettings: openSettings)
            self.target = target
            // Upwards from the pointer, like the Dock's menus: the strip sits at the bottom of the
            // window, often at the bottom of the screen. Left to find room below, AppKit put the menu
            // at the top of the screen when another display lies underneath.
            let menu = target.makeMenu()
            let pointer = NSEvent.mouseLocation
            menu.popUp(positioning: nil, at: NSPoint(x: pointer.x, y: pointer.y + menu.size.height), in: nil)
        }
    }

    /// Menu items only hold their target weakly, so the view keeps this one.
    final class MenuTarget: NSObject {
        private let settings: AppSettings
        private let openSettings: (() -> Void)?

        init(settings: AppSettings, openSettings: (() -> Void)?) {
            self.settings = settings
            self.openSettings = openSettings
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()
            for item in AppSettings.StatusBarItem.allCases {
                let menuItem = NSMenuItem(title: item.title, action: #selector(toggle(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = item.rawValue
                menuItem.state = settings.shows(item) ? .on : .off
                menu.addItem(menuItem)
            }
            if openSettings != nil {
                menu.addItem(.separator())
                let settingsItem = NSMenuItem(title: "Status Bar Settings…", action: #selector(showSettings), keyEquivalent: "")
                settingsItem.target = self
                menu.addItem(settingsItem)
            }
            return menu
        }

        @objc private func toggle(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let item = AppSettings.StatusBarItem(rawValue: raw) else { return }
            settings.setShows(item, !settings.shows(item))
        }

        @objc private func showSettings() { openSettings?() }
    }
}

extension View {
    /// The status bar's item menu on right-click, and the same toggles for VoiceOver's actions rotor,
    /// which cannot reach a menu that only a mouse opens.
    func statusBarMenu(_ settings: AppSettings, openSettings: (() -> Void)? = nil) -> some View {
        overlay { StatusBarMenuArea(settings: settings, openSettings: openSettings) }
            .accessibilityActions {
                ForEach(AppSettings.StatusBarItem.allCases) { item in
                    Button((settings.shows(item) ? "Hide " : "Show ") + item.title) {
                        settings.setShows(item, !settings.shows(item))
                    }
                }
            }
    }
}
