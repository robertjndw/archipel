import AppKit
import CoreText
import SwiftUI

enum DiffPaneRole {
    case old, new, unified
}

/// What the panes and gutters of one diff draw from. Shared by reference so expanding a fold or
/// receiving highlights updates both sides at once.
@MainActor
final class DiffLayout {
    let document: DiffDocument
    let rows: [DiffRow]
    var items: [DiffDisplayItem]
    var oldRuns: [HighlightRun] = []
    var newRuns: [HighlightRun] = []
    let oldOffsets: [Int]
    let newOffsets: [Int]
    let oldWidth: CGFloat
    let newWidth: CGFloat
    let hunks: [DiffHunk]
    /// Row index to hunk index, for the row that carries a hunk's drag handle.
    let hunkLeadRows: [Int: Int]

    init(document: DiffDocument, unified: Bool, showsAllLines: Bool) {
        self.document = document
        rows = unified ? document.unified : document.sideBySide
        items = showsAllLines ? DiffFolding.allRows(rows) : DiffFolding.items(for: rows)
        oldOffsets = document.old.lineOffsets()
        newOffsets = document.new.lineOffsets()
        oldWidth = DiffLineRenderer.width(of: document.old.lines)
        newWidth = DiffLineRenderer.width(of: document.new.lines)
        hunks = DiffHunks.hunks(in: document)
        hunkLeadRows = DiffHunks.leadRows(of: hunks, in: rows)
    }

    func side(_ isOld: Bool) -> (side: DiffSide, offsets: [Int], runs: [HighlightRun]) {
        isOld ? (document.old, oldOffsets, oldRuns) : (document.new, newOffsets, newRuns)
    }

    /// The line a pane shows for a row, and whether it comes from the old side.
    func line(for row: DiffRow, role: DiffPaneRole) -> (index: Int, isOld: Bool)? {
        switch role {
        case .old: row.old.map { ($0, true) }
        case .new: row.new.map { ($0, false) }
        case .unified: row.kind == .removed ? row.old.map { ($0, true) } : row.new.map { ($0, false) }
        }
    }
}

@MainActor
enum DiffLineRenderer {
    /// Drawing a minified 100k-character line costs more than it is worth; the rest is elided.
    static let maximumDrawnLength = 2_000
    static let textInset: CGFloat = 8

    static func ctLine(_ text: String, lineStart: Int, runs: [HighlightRun]) -> CTLine {
        var display = text
        var truncated = false
        if text.utf16.count > maximumDrawnLength {
            var end = text.utf16.index(text.utf16.startIndex, offsetBy: maximumDrawnLength)
            end = end.samePosition(in: text.unicodeScalars) ?? text.unicodeScalars.index(before: end)
            display = String(text[..<end])
            truncated = true
        }
        let length = display.utf16.count
        let string = NSMutableAttributedString(string: display + (truncated ? "\u{2026}" : ""), attributes: baseAttributes())
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)

        var index = firstRun(endingAfter: lineStart, in: runs)
        while index < runs.count {
            let run = runs[index]
            let start = max(run.location, lineStart) - lineStart
            if start >= length { break }
            let end = min(run.location + run.length - lineStart, length)
            if end > start {
                string.addAttribute(colorKey, value: EditorTheme.color(for: run.scope).cgColor, range: NSRange(location: start, length: end - start))
            }
            index += 1
        }
        return CTLineCreateWithAttributedString(string)
    }

    static func baseAttributes() -> [NSAttributedString.Key: Any] {
        [
            .font: EditorTheme.font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.textColor.cgColor,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraphStyle,
        ]
    }

    /// CoreText's own paragraph style, since it does not read NSParagraphStyle's tab interval.
    private static let paragraphStyle: CTParagraphStyle = {
        var interval = EditorTheme.characterWidth * CGFloat(EditorTheme.tabWidth)
        let stops = [CTTextTab]() as CFArray
        return withUnsafeBytes(of: &interval) { intervalBytes in
            withUnsafeBytes(of: stops) { stopsBytes in
                let settings = [
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: intervalBytes.count, value: intervalBytes.baseAddress!),
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: stopsBytes.count, value: stopsBytes.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }()

    private static func firstRun(endingAfter offset: Int, in runs: [HighlightRun]) -> Int {
        var low = 0
        var high = runs.count
        while low < high {
            let mid = (low + high) / 2
            if runs[mid].location + runs[mid].length <= offset { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Widest line, estimated from character counts and then measured exactly for the longest few,
    /// which catches wide characters without laying out every line.
    static func width(of lines: [String]) -> CGFloat {
        // Kept sorted widest first and capped, so a whole-file diff costs one pass instead of a sort.
        let measured = 12
        var longest: [(width: CGFloat, index: Int)] = []
        longest.reserveCapacity(measured + 1)
        for (index, line) in lines.enumerated() {
            var columns = 0
            for unit in line.utf16 { columns += unit == 9 ? EditorTheme.tabWidth : 1 }
            let width = CGFloat(min(columns, maximumDrawnLength + 1)) * EditorTheme.characterWidth
            guard longest.count < measured || width > longest[measured - 1].width else { continue }
            let position = longest.firstIndex { $0.width < width } ?? longest.count
            longest.insert((width, index), at: position)
            if longest.count > measured { longest.removeLast() }
        }
        var widest = longest.first?.width ?? 0
        for candidate in longest {
            let line = ctLine(lines[candidate.index], lineStart: 0, runs: [])
            widest = max(widest, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        }
        return (widest + textInset * 2 + 40).rounded(.up)
    }
}

/// One column of diff text. Virtualized by drawing only the rows inside the dirty rect: every row has
/// the same height, so finding them is a division rather than a layout pass.
@MainActor
final class DiffPaneView: NSView {
    let role: DiffPaneRole
    var layoutState: DiffLayout? {
        didSet { needsDisplay = true }
    }
    var onExpandFold: ((Int) -> Void)?
    /// The display item under the mouse, or nil when it leaves; drives the gutter's add button.
    var onHover: ((Int?) -> Void)?

    init(role: DiffPaneRole) {
        self.role = role
        super.init(frame: .zero)
        // AppKit no longer clips views by default, and a ruler's dirty rect can reach into the text beside it.
        clipsToBounds = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    var contentWidth: CGFloat {
        guard let layoutState else { return 0 }
        switch role {
        case .old: return layoutState.oldWidth
        case .new: return layoutState.newWidth
        case .unified: return max(layoutState.oldWidth, layoutState.newWidth)
        }
    }

    func updateSize() {
        guard let clip = superview as? NSClipView else { return }
        let rows = CGFloat(layoutState?.items.count ?? 0)
        let size = NSSize(
            width: max(contentWidth, clip.bounds.width),
            height: max(rows * EditorTheme.lineHeight + EditorTheme.lineHeight, clip.bounds.height)
        )
        if frame.size != size { setFrameSize(size) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = Int(point.y / EditorTheme.lineHeight)
        guard let items = layoutState?.items, items.indices.contains(index), case .fold = items[index] else {
            super.mouseDown(with: event)
            return
        }
        onExpandFold?(index)
    }

    override func mouseMoved(with event: NSEvent) {
        guard let onHover else { return }
        let y = convert(event.locationInWindow, from: nil).y
        onHover(y >= 0 ? Int(y / EditorTheme.lineHeight) : nil)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        guard let layoutState, let context = NSGraphicsContext.current?.cgContext else { return }
        let height = EditorTheme.lineHeight
        let first = max(0, Int(dirtyRect.minY / height))
        let last = min(layoutState.items.count - 1, Int(dirtyRect.maxY / height))
        guard first <= last else { return }

        for index in first...last {
            let rect = NSRect(x: 0, y: CGFloat(index) * height, width: bounds.width, height: height)
            switch layoutState.items[index] {
            case .fold(let range):
                drawFold(hiding: range.count, in: rect, context: context)
            case .row(let rowIndex):
                drawRow(layoutState.rows[rowIndex], layout: layoutState, in: rect, context: context)
            }
        }
    }

    private func drawRow(_ row: DiffRow, layout: DiffLayout, in rect: NSRect, context: CGContext) {
        guard let (lineIndex, isOld) = layout.line(for: row, role: role) else {
            drawFiller(in: rect, context: context)
            return
        }
        // A pane only gets a line for a changed row when that side of the change exists.
        if row.kind != .context {
            (isOld ? EditorTheme.removedLine : EditorTheme.addedLine).setFill()
            rect.fill()
        }

        let (side, offsets, runs) = layout.side(isOld)
        let text = side.lines[lineIndex]
        let line = DiffLineRenderer.ctLine(text, lineStart: offsets[lineIndex], runs: runs)
        let x = DiffLineRenderer.textInset

        if let emphasis = isOld ? row.oldEmphasis : row.newEmphasis, emphasis.lowerBound < DiffLineRenderer.maximumDrawnLength {
            let start = CTLineGetOffsetForStringIndex(line, emphasis.lowerBound, nil)
            let end = CTLineGetOffsetForStringIndex(line, min(emphasis.upperBound, DiffLineRenderer.maximumDrawnLength), nil)
            (isOld ? EditorTheme.removedEmphasis : EditorTheme.addedEmphasis).setFill()
            NSBezierPath(roundedRect: NSRect(x: x + start, y: rect.minY + 1, width: max(end - start, 2), height: rect.height - 2), xRadius: 2, yRadius: 2).fill()
        }

        let width = Self.draw(line, x: x, in: rect, context: context)

        let otherSide = isOld ? layout.document.new : layout.document.old
        if lineIndex == side.lines.count - 1, side.missingNewlineAtEnd, !otherSide.missingNewlineAtEnd || otherSide.lines.isEmpty {
            let label = String(localized: "No newline at end of file") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: EditorTheme.gutterFont, .foregroundColor: NSColor.tertiaryLabelColor]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: x + width + 16, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }

    private func drawFiller(in rect: NSRect, context: CGContext) {
        context.saveGState()
        context.clip(to: rect)
        EditorTheme.filler.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: NSPoint(x: x, y: rect.maxY))
            path.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += 6
        }
        path.stroke()
        context.restoreGState()
    }

    private func drawFold(hiding count: Int, in rect: NSRect, context: CGContext) {
        EditorTheme.foldBackground.setFill()
        rect.fill()
        var x = DiffLineRenderer.textInset
        if let symbol = Self.foldSymbol {
            let size = symbol.size
            symbol.draw(in: NSRect(x: x, y: (rect.midY - size.height / 2).rounded(), width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            x += size.width + 5
        }
        let format = count == 1 ? String(localized: "%lld unchanged line") : String(localized: "%lld unchanged lines")
        let label = NSAttributedString(string: String(format: format, count), attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.secondaryLabelColor.cgColor,
        ])
        Self.draw(CTLineCreateWithAttributedString(label), x: x, in: rect, context: context)
    }

    /// Draws a line vertically centred in `rect`. CoreText's text position and matrix live outside
    /// the graphics state, so both are set every time rather than trusted from a previous draw.
    @discardableResult
    static func draw(_ line: CTLine, x: CGFloat, in rect: NSRect, context: CGContext) -> CGFloat {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let baseline = rect.minY + ((rect.height - ascent - descent) / 2 + ascent).rounded()
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, context)
        context.restoreGState()
        context.textMatrix = .identity
        return width
    }

    /// Tinted once up front: a symbol image drawn straight into the pane comes out black or not at all.
    private static let foldSymbol: NSImage? = {
        guard let symbol = NSImage(systemSymbolName: "arrow.up.and.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) else { return nil }
        return NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.secondaryLabelColor.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }()

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? {
        switch role {
        case .old: String(localized: "Original")
        case .new: String(localized: "Modified")
        case .unified: String(localized: "Changes")
        }
    }
}

/// Line numbers for a diff pane, laid out beside its scroll view rather than as an NSRulerView: a
/// floating ruler covers the start of a non-text document view once its width changes.
///
/// With commenting on, a lane left of the numbers shows an add button on the hovered row and a
/// marker on commented rows; clicking anywhere in the gutter row opens the comment.
@MainActor
final class DiffGutterView: NSView {
    static let commentLaneWidth: CGFloat = 16

    private let role: DiffPaneRole
    private weak var pane: DiffPaneView?
    private(set) var thickness: CGFloat = 0

    var commentsEnabled = false
    var markedItems: Set<Int> = [] {
        didSet { if markedItems != oldValue { needsDisplay = true } }
    }
    /// The container only sets rows that can take a comment.
    var hoveredItem: Int? {
        didSet {
            guard hoveredItem != oldValue else { return }
            if let oldValue { setNeedsDisplay(rowRect(for: oldValue)) }
            if let hoveredItem { setNeedsDisplay(rowRect(for: hoveredItem)) }
        }
    }
    var onHover: ((Int?) -> Void)?
    var onComment: ((Int) -> Void)?
    /// Shows a grip on the first row of each hunk that can be dragged out as text. Only the pane
    /// that shows the new side gets one, because the text points at new line numbers.
    var hunkHandlesEnabled = false {
        didSet { if hunkHandlesEnabled != oldValue { needsDisplay = true } }
    }
    /// The text and a short label for the hunk whose handle sits on a display item.
    var hunkDragPayload: ((Int) -> (text: String, label: String)?)?
    private var pendingHunkDrag: Int?
    /// What VoiceOver calls the comment button of a display item; nil when the item takes no comment.
    var commentAccessibilityLabel: ((Int) -> String?)?
    private var accessibilityButtons: [Int: DiffCommentAccessibilityButton] = [:]

    init(pane: DiffPaneView) {
        role = pane.role
        self.pane = pane
        super.init(frame: .zero)
        clipsToBounds = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var columnWidth: CGFloat {
        guard let document = pane?.layoutState?.document else { return 0 }
        let largest = max(document.old.numbers.last ?? 0, document.new.numbers.last ?? 0)
        return CGFloat(max(3, String(largest).count)) * EditorTheme.gutterDigitWidth + 12
    }

    private var laneWidth: CGFloat {
        commentsEnabled ? Self.commentLaneWidth : 0
    }

    private static let handleWidth: CGFloat = 12
    private var handleLaneWidth: CGFloat { hunkHandlesEnabled ? Self.handleWidth : 0 }

    /// Returns whether the width changed, so the container knows to lay out again.
    @discardableResult
    func updateThickness() -> Bool {
        let width = (laneWidth + columnWidth * (role == .unified ? 2 : 1) + 6 + handleLaneWidth).rounded(.up)
        guard width != thickness else { return false }
        thickness = width
        return true
    }

    /// A display item's row in this view's coordinates, which scroll with the pane.
    func rowRect(for item: Int) -> NSRect {
        guard let pane else { return .zero }
        let y = convert(NSPoint(x: 0, y: CGFloat(item) * EditorTheme.lineHeight), from: pane).y
        return NSRect(x: 0, y: y, width: bounds.width, height: EditorTheme.lineHeight)
    }

    private func item(at point: NSPoint) -> Int? {
        guard let pane, let count = pane.layoutState?.items.count else { return nil }
        let y = pane.convert(point, from: self).y
        guard y >= 0 else { return nil }
        let item = Int(y / EditorTheme.lineHeight)
        return item < count ? item : nil
    }

    /// The buttons are cached by display item, which names a different row once the layout or its
    /// folds change.
    func invalidateAccessibility() {
        accessibilityButtons.removeAll()
    }

    override func scrollWheel(with event: NSEvent) {
        pane?.enclosingScrollView?.scrollWheel(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(item(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let item = item(at: point)
        pendingHunkDrag = nil
        if hunkHandlesEnabled, let item, point.x >= bounds.width - Self.handleWidth, hunkDragPayload?(item) != nil {
            // The handle sits inside the comment click area; it only drags.
            pendingHunkDrag = item
            return
        }
        guard commentsEnabled, let item else {
            super.mouseDown(with: event)
            return
        }
        onComment?(item)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let item = pendingHunkDrag, let payload = hunkDragPayload?(item) else { return }
        pendingHunkDrag = nil
        let dragItem = NSDraggingItem(pasteboardWriter: payload.text as NSString)
        let image = Self.dragImage(label: payload.label)
        let origin = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: origin.x - 8, y: origin.y - image.size.height / 2, width: image.size.width, height: image.size.height), contents: image)
        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        pendingHunkDrag = nil
    }

    private static func dragImage(label: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
        let text = label as NSString
        let textSize = text.size(withAttributes: attributes)
        let size = NSSize(width: ceil(textSize.width) + 16, height: ceil(textSize.height) + 8)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).stroke()
            text.draw(at: NSPoint(x: 8, y: 4), withAttributes: attributes)
            return true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        drawRows(in: dirtyRect)
    }

    private func drawRows(in dirtyRect: NSRect) {
        guard let pane, let layout = pane.layoutState else { return }
        let height = EditorTheme.lineHeight
        let visible = pane.visibleRect
        // Hovering redraws a single row; only the rows it touches are drawn again.
        let dirty = pane.convert(dirtyRect, from: self)
        let first = max(0, Int(max(visible.minY, dirty.minY) / height))
        let last = min(layout.items.count - 1, Int(min(visible.maxY, dirty.maxY) / height))
        guard first <= last else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: EditorTheme.gutterFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let lane = laneWidth
        let column = columnWidth

        for index in first...last {
            let y = convert(NSPoint(x: 0, y: CGFloat(index) * height), from: pane).y
            let rect = NSRect(x: 0, y: y, width: bounds.width, height: height)
            guard case .row(let rowIndex) = layout.items[index] else {
                EditorTheme.foldBackground.setFill()
                rect.fill()
                continue
            }
            let row = layout.rows[rowIndex]
            switch role {
            case .old, .new:
                guard let (lineIndex, isOld) = layout.line(for: row, role: role) else { continue }
                if row.kind != .context {
                    (isOld ? EditorTheme.removedGutter : EditorTheme.addedGutter).setFill()
                    rect.fill()
                }
                let number = layout.side(isOld).side.numbers[lineIndex]
                draw(number, rightEdge: lane + column, in: rect, attributes: attributes)
            case .unified:
                if row.kind == .removed || row.kind == .added {
                    (row.kind == .removed ? EditorTheme.removedGutter : EditorTheme.addedGutter).setFill()
                    rect.fill()
                }
                if let old = row.old { draw(layout.document.old.numbers[old], rightEdge: lane + column, in: rect, attributes: attributes) }
                if let new = row.new { draw(layout.document.new.numbers[new], rightEdge: lane + column * 2, in: rect, attributes: attributes) }
            }
            if hunkHandlesEnabled, case .row(let rowIndex) = layout.items[index], layout.hunkLeadRows[rowIndex] != nil {
                drawGrip(in: NSRect(x: bounds.width - Self.handleWidth, y: rect.minY, width: Self.handleWidth, height: height))
            }
            if commentsEnabled {
                let laneRect = NSRect(x: 0, y: rect.minY, width: lane, height: height)
                if markedItems.contains(index) {
                    drawCommentMarker(in: laneRect)
                } else if hoveredItem == index {
                    drawAddButton(in: laneRect)
                }
            }
        }
    }

    private func draw(_ number: Int, rightEdge: CGFloat, in rect: NSRect, attributes: [NSAttributedString.Key: Any]) {
        let label = String(number) as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: rightEdge - 6 - size.width, y: rect.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawGrip(in rect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        for column in 0..<2 {
            for row in 0..<3 {
                let x = rect.midX - 3.5 + CGFloat(column) * 4
                let y = rect.midY - 5 + CGFloat(row) * 4
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 2.5, height: 2.5)).fill()
            }
        }
    }

    /// Drawn as shapes in the accent colour rather than from a symbol image, so it follows the
    /// appearance and accent colour at draw time instead of whatever an image cached.
    private func drawCommentMarker(in lane: NSRect) {
        let body = NSRect(x: (lane.midX - 5.5).rounded(), y: (lane.midY - 5).rounded(), width: 11, height: 8)
        let bubble = NSBezierPath(roundedRect: body, xRadius: 2.5, yRadius: 2.5)
        bubble.move(to: NSPoint(x: body.minX + 2.5, y: body.maxY - 1))
        bubble.line(to: NSPoint(x: body.minX + 2.5, y: body.maxY + 3))
        bubble.line(to: NSPoint(x: body.minX + 6.5, y: body.maxY - 1))
        bubble.close()
        NSColor.controlAccentColor.setFill()
        bubble.fill()
    }

    private func drawAddButton(in lane: NSRect) {
        let box = NSRect(x: (lane.midX - 6.5).rounded(), y: (lane.midY - 6.5).rounded(), width: 13, height: 13)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        let plus = NSBezierPath()
        plus.lineWidth = 1.5
        plus.move(to: NSPoint(x: box.minX + 3.5, y: box.midY))
        plus.line(to: NSPoint(x: box.maxX - 3.5, y: box.midY))
        plus.move(to: NSPoint(x: box.midX, y: box.minY + 3.5))
        plus.line(to: NSPoint(x: box.midX, y: box.maxY - 3.5))
        NSColor.white.setStroke()
        plus.stroke()
    }

    // MARK: Accessibility

    // The rows are drawn, not views, so each visible commentable row is offered as a button of its
    // own; that is the only way VoiceOver can reach a single line's comment.

    override func isAccessibilityElement() -> Bool { commentsEnabled }
    override func accessibilityRole() -> NSAccessibility.Role? { commentsEnabled ? .group : super.accessibilityRole() }
    override func accessibilityLabel() -> String? {
        guard commentsEnabled else { return super.accessibilityLabel() }
        switch role {
        case .old: return String(localized: "Original Line Comments")
        case .new: return String(localized: "Modified Line Comments")
        case .unified: return String(localized: "Line Comments")
        }
    }

    override func accessibilityChildren() -> [Any]? {
        guard commentsEnabled, let pane, let layout = pane.layoutState, let commentAccessibilityLabel else {
            return super.accessibilityChildren()
        }
        let height = EditorTheme.lineHeight
        let visible = pane.visibleRect
        let first = max(0, Int(visible.minY / height))
        let last = min(layout.items.count - 1, Int(visible.maxY / height))
        guard first <= last else { return [] }
        var children: [Any] = []
        for index in first...last {
            guard let label = commentAccessibilityLabel(index) else { continue }
            // Reused per item so VoiceOver keeps its place while the view scrolls.
            let button = accessibilityButtons[index] ?? {
                let button = DiffCommentAccessibilityButton()
                button.setAccessibilityRole(.button)
                button.setAccessibilityParent(self)
                button.press = { [weak self] in self?.onComment?(index) }
                accessibilityButtons[index] = button
                return button
            }()
            button.setAccessibilityLabel(label)
            // The parent space counts up from the bottom edge, whatever `isFlipped` says.
            let row = rowRect(for: index)
            button.setAccessibilityFrameInParentSpace(
                NSRect(x: row.minX - bounds.minX, y: bounds.maxY - row.maxY, width: row.width, height: row.height)
            )
            children.append(button)
        }
        return children
    }
}

extension DiffGutterView: NSDraggingSource {
    nonisolated func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

private final class DiffCommentAccessibilityButton: NSAccessibilityElement {
    var press: (() -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        press()
        return true
    }
}

#if DEBUG
// The pane is only ever hosted by DiffContainerView, so these show it through DiffPreview with
// content that exercises the drawing edge cases.

#Preview("Very Long Lines") {
    DiffPreview(PreviewSamples.longLines)
        .frame(width: 900, height: 200)
}

#Preview("No Newline at End of File") {
    DiffPreview(PreviewSamples.missingNewline)
        .frame(width: 900, height: 200)
}

#Preview("No Grammar") {
    DiffPreview(PreviewSamples.plainText, presentation: .inline)
        .frame(width: 600, height: 200)
}

#Preview("Very Long Lines, Dark") {
    DiffPreview(PreviewSamples.longLines, presentation: .inline)
        .frame(width: 900, height: 220)
        .preferredColorScheme(.dark)
}
#endif
