import AppKit

/// Swaps the Dock and Finder icon for one of the alternates in Settings.
///
/// macOS has no alternate app icons like iOS, so this does what Ghostty does: the running app's Dock
/// tile gets the image right away, and the bundle gets a custom Finder icon so the Dock and Finder
/// keep it while Archipel is closed. A Sparkle update replaces the bundle and drops that custom
/// icon, which is why launch applies it again.
@MainActor
enum AppIconChanger {
    static func apply(_ icon: AppSettings.AppIcon, atLaunch: Bool = false) {
        let image = icon.image
        // nil puts back the icon from the bundle, which is the one that follows dark mode and tinting.
        NSApp.applicationIconImage = image
        // Nothing was written for the default icon, so a normal launch never touches the bundle.
        if atLaunch, image == nil { return }
        let path = Bundle.main.bundlePath
        Task { await BundleIconWriter.shared.write(image, toBundleAt: path) }
    }
}

extension AppSettings.AppIcon {
    /// The rendered icon from the asset catalog, made by scripts/render-app-icons.sh. nil for the
    /// default icon, which the system draws from Archipel.icon itself.
    var image: NSImage? {
        guard let assetName else { return nil }
        return NSImage(named: assetName)
    }

    /// The image for a Settings tile. The default icon has two, a light and a dark render.
    var previewImage: NSImage? {
        image ?? NSImage(named: "AppIconSystemLight")
    }

    private var assetName: String? {
        self == .system ? nil : "AppIcon" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

/// One write at a time: NSWorkspace writes an `Icon\r` file and extended attributes into the
/// bundle, and two quick picks in Settings must not interleave and leave the older one behind.
private actor BundleIconWriter {
    static let shared = BundleIconWriter()

    func write(_ image: NSImage?, toBundleAt path: String) {
        // Fails when the bundle isn't writable, e.g. an admin installed it for every user. The Dock
        // tile still changes while the app runs, so there's nothing to tell the user.
        NSWorkspace.shared.setIcon(image, forFile: path, options: [])
        NSWorkspace.shared.noteFileSystemChanged(path)
    }
}
