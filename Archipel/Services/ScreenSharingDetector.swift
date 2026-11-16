import CoreGraphics
import Darwin

/// Whether other people can probably see this screen right now, from signals that need no
/// permission. Cheap enough to call before every notification (about a millisecond).
///
/// macOS offers no public API for "the screen is being captured": ScreenCaptureKit only answers
/// after the Screen Recording permission prompt, and the menu bar's recording indicator is private.
/// So this looks for the cases that leave a trace:
/// - a mirrored display, as when presenting on a projector or through AirPlay;
/// - the helper processes that only run while a share is live: `screensharingd` serves an incoming
///   Screen Sharing or Remote Management session, and Zoom shares through `CptHost`.
///
/// Browser-based calls (Meet, Teams on the web) capture inside the browser process and cannot be
/// told apart from it, so they go unnoticed.
///
/// Focus modes are deliberately not detected here. `INFocusStatusCenter` needs the Communication
/// Notifications entitlement, and macOS already keeps banners of apps a Focus does not allow
/// out of sight on its own.
enum ScreenSharingDetector {
    static let sharingProcessNames: Set<String> = ["screensharingd", "CptHost"]

    static func isSharing() -> Bool {
        isMirroringDisplay() || isRunningSharingProcess()
    }

    private static func isMirroringDisplay() -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return false }
        return displays.prefix(Int(count)).contains { CGDisplayIsInMirrorSet($0) != 0 }
    }

    /// Reads the process table the way `ps` does. Unlike libproc, sysctl also names processes of
    /// other users, and `screensharingd` runs as root.
    private static func isRunningSharingProcess() -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return false }
        // Room for processes started between the two calls.
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else { return false }
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride).contains { process in
            // p_comm is the executable name cut to 16 bytes, enough for the names above.
            let name = withUnsafeBytes(of: process.kp_proc.p_comm) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            return sharingProcessNames.contains(name)
        }
    }
}
