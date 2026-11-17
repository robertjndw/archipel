import AppKit
import SwiftUI
import UISupport

/// SF Symbol names for files, shared with the app so editor tabs match the sidebar.
public enum FileIcon {
    public static let folder = "folder"

    public static func symbol(for filename: String) -> String {
        FileSymbol.name(for: filename)
    }
}
