import AppKit
import GhosttyKit

/// Dragging files, links or text onto a terminal pastes them, like Ghostty's
/// own app and Terminal.app do.
extension SurfaceView {
    static let droppedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    /// The trailing space keeps whatever the user types next from running
    /// into the last path, which matters most for agents' prompts.
    static func droppedText(forFiles urls: [URL]) -> String {
        guard !urls.isEmpty else { return "" }
        return urls.map { NSPasteboard.shellEscape($0.path(percentEncoded: false)) }.joined(separator: " ") + " "
    }

    func paste(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_paste_text(surface, ptr, UInt(text.utf8.count))
        }
    }

    /// What dropping the pasteboard's contents would paste, or nil if nothing.
    private func droppedText(from pasteboard: NSPasteboard) -> String? {
        let types = pasteboard.types ?? []
        // Only when a URL type is really there: NSURL also reads plain strings
        // and would turn a dropped word into a relative URL.
        if types.contains(.fileURL) || types.contains(.URL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            if urls.allSatisfy(\.isFileURL) { return Self.droppedText(forFiles: urls) }
            return urls.map { NSPasteboard.shellEscape($0.absoluteString) }.joined(separator: " ")
        }
        guard let string = pasteboard.string(forType: .string), !string.isEmpty, acceptsDroppedText(string) else { return nil }
        return string
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard surface != nil, droppedText(from: sender.draggingPasteboard) != nil else { return [] }
        showDropHighlight(true)
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        (dropHighlightLayer?.opacity ?? 0) > 0 ? .copy : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        showDropHighlight(false)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        showDropHighlight(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        showDropHighlight(false)
        guard let text = droppedText(from: sender.draggingPasteboard) else { return false }
        // After the drag session unwinds: a paste that trips paste protection
        // puts up a sheet, which should not start inside the drop callback.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.window?.makeFirstResponder(self)
                self.paste(text)
            }
        }
        return true
    }

    /// A sublayer rather than a subview: Ghostty owns this view's layer, and
    /// AppKit does not promise subviews of a layer-hosting view get drawn.
    private func showDropHighlight(_ visible: Bool) {
        guard let layer else { return }
        guard visible else {
            dropHighlightLayer?.opacity = 0
            return
        }
        let highlight: CALayer
        if let existing = dropHighlightLayer {
            highlight = existing
        } else {
            highlight = CALayer()
            highlight.opacity = 0
            highlight.borderWidth = 2
            highlight.zPosition = 1
            layer.addSublayer(highlight)
            dropHighlightLayer = highlight
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = layer.bounds
        effectiveAppearance.performAsCurrentDrawingAppearance {
            highlight.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        }
        CATransaction.commit()
        // Left to the implicit animation, which fades it in.
        highlight.opacity = 1
    }
}
