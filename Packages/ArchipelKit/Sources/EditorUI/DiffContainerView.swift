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
    var commenting: DiffCommentContext?

    func makeNSView(context: Context) -> DiffContainerView {
        DiffContainerView()
    }

    func updateNSView(_ view: DiffContainerView, context: Context) {
        view.configure(document: document, version: version, presentation: presentation, showsAllLines: showsAllLines, highlights: highlights)
        view.configureComments(commenting)
    }
}

/// Where comments made in a diff go, and the ones already on the file it shows.
struct DiffCommentContext {
    let store: ReviewCommentStore
    let root: URL
    let path: String
    let staged: Bool
    /// Only this file's comments for the same staged state.
    let comments: [ReviewComment]
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
    private var commenting: DiffCommentContext?
    private var commentEditor: DiffCommentEditorSession?

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
        if rebuildLayout { updateCommentMarkers() }
    }

    /// Separate from `configure` so adding a comment only touches the gutters, never the layout.
    func configureComments(_ commenting: DiffCommentContext?) {
        let wasEnabled = self.commenting != nil
        let changed = commenting?.comments != self.commenting?.comments
        self.commenting = commenting
        if wasEnabled != (commenting != nil) {
            for pane in panes {
                pane.gutter.commentsEnabled = commenting != nil
                if pane.gutter.updateThickness() { needsLayout = true }
                pane.gutter.needsDisplay = true
            }
        }
        if changed { updateCommentMarkers() }
    }

    private func updateCommentMarkers() {
        let anchors = Set(commenting?.comments.map(\.anchor) ?? [])
        for pane in panes {
            pane.gutter.hoveredItem = nil
            pane.gutter.invalidateAccessibility()
            guard let layoutState else {
                pane.gutter.markedItems = []
                continue
            }
            pane.gutter.markedItems = DiffCommentAnchoring.markedItems(
                layoutState.items, rows: layoutState.rows, role: pane.view.role, document: layoutState.document, anchors: anchors
            )
        }
    }

    private func makePanes(_ presentation: DiffPresentation) {
        // The popover points into a gutter that is about to go away.
        commentEditor?.dismiss()
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
            view.onHover = { [weak self, weak gutter] item in
                guard let self, let gutter else { return }
                hover(item, in: gutter, role: role)
            }
            gutter.onHover = view.onHover
            gutter.onComment = { [weak self, weak gutter] item in
                guard let self, let gutter else { return }
                editComment(at: item, in: gutter, role: role)
            }
            gutter.commentAccessibilityLabel = { [weak self] item in
                self?.commentAccessibilityLabel(at: item, role: role)
            }
            gutter.commentsEnabled = commenting != nil
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
        updateCommentMarkers()
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
            // Scrolling under a resting mouse sends no mouseMoved, so the add button would stay on the old row.
            if pane.gutter.hoveredItem != nil, let window {
                let point = pane.view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
                pane.view.onHover?(pane.view.visibleRect.contains(point) ? Int(point.y / EditorTheme.lineHeight) : nil)
            }
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { commentEditor?.dismiss() }
    }

    // MARK: Comments

    private func commentAnchor(at item: Int, role: DiffPaneRole) -> (anchor: DiffLineAnchor, text: String)? {
        guard let layoutState, layoutState.items.indices.contains(item), case .row(let rowIndex) = layoutState.items[item] else { return nil }
        return DiffCommentAnchoring.anchor(for: layoutState.rows[rowIndex], role: role, in: layoutState.document)
    }

    private func hover(_ item: Int?, in gutter: DiffGutterView, role: DiffPaneRole) {
        guard commenting != nil, let item, commentAnchor(at: item, role: role) != nil else {
            gutter.hoveredItem = nil
            return
        }
        gutter.hoveredItem = item
    }

    private func commentAccessibilityLabel(at item: Int, role: DiffPaneRole) -> String? {
        guard let commenting, let (anchor, _) = commentAnchor(at: item, role: role) else { return nil }
        let line = Self.lineDescription(anchor)
        if let comment = commenting.comments.first(where: { $0.anchor == anchor }) {
            return String(localized: "Comment on \(line): \(comment.body)")
        }
        return String(localized: "Add Comment to \(line)")
    }

    private static func lineDescription(_ anchor: DiffLineAnchor) -> String {
        anchor.side == .old ? String(localized: "removed line \(anchor.line)") : String(localized: "line \(anchor.line)")
    }

    private func editComment(at item: Int, in gutter: DiffGutterView, role: DiffPaneRole) {
        guard let commenting, let (anchor, text) = commentAnchor(at: item, role: role) else { return }
        let existing = commenting.comments.first { $0.anchor == anchor }
        let store = commenting.store
        let root = commenting.root
        commentEditor?.dismiss()
        let editor = DiffCommentEditorSession(
            title: String(localized: "Comment on \(Self.lineDescription(anchor))"),
            code: existing?.lineText ?? text,
            body: existing?.body
        ) { outcome in
            switch (outcome, existing) {
            case (.save(let body), let existing?):
                store.update(existing.id, body: body, in: root)
            case (.save(let body), nil):
                store.add(ReviewComment(path: commenting.path, staged: commenting.staged, side: anchor.side, line: anchor.line, lineText: text, body: body), in: root)
            case (.delete, let existing?):
                store.remove(existing.id, in: root)
            case (.delete, nil):
                break
            }
        }
        commentEditor = editor
        editor.show(relativeTo: gutter.rowRect(for: item), of: gutter)
    }
}
