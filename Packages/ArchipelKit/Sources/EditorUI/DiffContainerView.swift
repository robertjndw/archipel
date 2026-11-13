import AppKit
import SwiftUI

enum DiffPresentation: String, CaseIterable, Sendable {
    case sideBySide, inline
}

struct DiffHighlights: Equatable, Sendable {
    var documentVersion: Int
    var old: [HighlightRun]
    var new: [HighlightRun]
}

struct DiffTextView: NSViewRepresentable {
    let document: DiffDocument
    let version: Int
    let presentation: DiffPresentation
    let showsAllLines: Bool
    let highlights: DiffHighlights?

    func makeNSView(context: Context) -> DiffContainerView {
        DiffContainerView()
    }

    func updateNSView(_ view: DiffContainerView, context: Context) {
        view.configure(document: document, version: version, presentation: presentation, showsAllLines: showsAllLines, highlights: highlights)
    }
}

/// Hosts one pane (inline) or two panes (side by side) and keeps the two scrolled together.
@MainActor
final class DiffContainerView: NSView {
    private struct Pane {
        let scrollView: NSScrollView
        let view: DiffPaneView
        let gutter: DiffGutterView
    }

    private var panes: [Pane] = []
    private var layoutState: DiffLayout?
    private var presentation: DiffPresentation?
    private var version = -1
    private var showsAllLines = false
    private var highlightVersion: Int?
    private var isSyncing = false

    override var isFlipped: Bool { true }

    func configure(document: DiffDocument, version: Int, presentation: DiffPresentation, showsAllLines: Bool, highlights: DiffHighlights?) {
        let rebuildPanes = presentation != self.presentation
        let rebuildLayout = rebuildPanes || version != self.version || showsAllLines != self.showsAllLines
        if rebuildPanes {
            self.presentation = presentation
            makePanes(presentation)
        }
        if rebuildLayout {
            self.version = version
            self.showsAllLines = showsAllLines
            layoutState = DiffLayout(document: document, unified: presentation == .inline, showsAllLines: showsAllLines)
            highlightVersion = nil
        }
        if let highlights, highlights.documentVersion == version, highlightVersion != version || rebuildLayout {
            layoutState?.oldRuns = highlights.old
            layoutState?.newRuns = highlights.new
            highlightVersion = version
        }
        if rebuildLayout || highlightVersion == version {
            for pane in panes {
                pane.view.layoutState = layoutState
                if pane.gutter.updateThickness() { needsLayout = true }
            }
            refreshPanes()
        }
    }

    private func makePanes(_ presentation: DiffPresentation) {
        for pane in panes {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: pane.scrollView.contentView)
            pane.scrollView.removeFromSuperview()
            pane.gutter.removeFromSuperview()
        }
        let roles: [DiffPaneRole] = presentation == .inline ? [.unified] : [.old, .new]
        panes = roles.map { role in
            let view = DiffPaneView(role: role)
            let gutter = DiffGutterView(pane: view)
            let scrollView = NSScrollView()
            scrollView.drawsBackground = true
            scrollView.backgroundColor = .textBackgroundColor
            scrollView.borderType = .noBorder
            scrollView.hasHorizontalScroller = true
            // Side by side, the left pane follows the right one, so a single scroller is enough.
            scrollView.hasVerticalScroller = role != .old
            scrollView.autohidesScrollers = true
            scrollView.documentView = view
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipViewScrolled(_:)), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
            view.onExpandFold = { [weak self] index in self?.expandFold(at: index) }
            addSubview(scrollView)
            addSubview(gutter)
            return Pane(scrollView: scrollView, view: view, gutter: gutter)
        }
        needsLayout = true
    }

    private func expandFold(at index: Int) {
        guard let layoutState else { return }
        layoutState.items = DiffFolding.expanding(layoutState.items, at: index)
        refreshPanes()
    }

    private func refreshPanes() {
        for pane in panes {
            pane.view.updateSize()
            pane.view.needsDisplay = true
            pane.gutter.needsDisplay = true
        }
    }

    override func layout() {
        super.layout()
        let columns: [(CGFloat, CGFloat)]
        if panes.count == 2 {
            let left = (bounds.width / 2).rounded(.down)
            columns = [(0, left), (left + 1, bounds.width - left - 1)]
        } else {
            columns = [(0, bounds.width)]
        }
        for (pane, (x, width)) in zip(panes, columns) {
            let gutterWidth = pane.gutter.thickness
            pane.gutter.frame = NSRect(x: x, y: 0, width: gutterWidth, height: bounds.height)
            pane.scrollView.frame = NSRect(x: x + gutterWidth, y: 0, width: max(0, width - gutterWidth), height: bounds.height)
            pane.view.updateSize()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard panes.count == 2 else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: panes[1].gutter.frame.minX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    /// Both axes follow: the same row stays level on both sides, and a long changed line can be read
    /// across without scrolling each half separately.
    @objc private func clipViewScrolled(_ notification: Notification) {
        guard let source = notification.object as? NSClipView else { return }
        for pane in panes where pane.scrollView.contentView === source {
            pane.gutter.needsDisplay = true
        }
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        for pane in panes where pane.scrollView.contentView !== source {
            let clip = pane.scrollView.contentView
            var target = clip.bounds
            target.origin = source.bounds.origin
            let constrained = clip.constrainBoundsRect(target)
            if constrained.origin != clip.bounds.origin {
                clip.setBoundsOrigin(constrained.origin)
                pane.scrollView.reflectScrolledClipView(clip)
            }
            pane.gutter.needsDisplay = true
        }
    }
}
