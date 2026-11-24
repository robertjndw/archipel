import AppKit
import SwiftUI

/// Editable source text: TextKit 1 with non-contiguous layout, so a 20k-line file only lays out what
/// is on screen, plus a line number ruler and the standard find and replace bar. The text storage
/// belongs to the buffer; each view adds its own layout manager to it.
struct CodeTextView: NSViewRepresentable {
    let buffer: TextBuffer

    func makeNSView(context: Context) -> CodeScrollView {
        CodeScrollView(buffer: buffer)
    }

    func updateNSView(_ view: CodeScrollView, context: Context) {}

    static func dismantleNSView(_ view: CodeScrollView, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class CodeScrollView: NSScrollView, NSTextViewDelegate {
    let textView: CodeNSTextView
    private let ruler: LineNumberRuler
    private let buffer: TextBuffer
    private let layoutManager = NSLayoutManager()
    private var highlightTask: Task<Void, Never>?
    private var editCount = 0

    /// Long enough to skip highlighting between keystrokes, short enough to feel immediate.
    private static let highlightDelay = Duration.milliseconds(250)

    init(buffer: TextBuffer) {
        self.buffer = buffer
        layoutManager.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: 1_000_000, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 4
        layoutManager.addTextContainer(container)
        buffer.textStorage.addLayoutManager(layoutManager)

        textView = CodeNSTextView(frame: .zero, textContainer: container)
        ruler = LineNumberRuler(textView: textView)
        super.init(frame: .zero)

        configureTextView()
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        documentView = textView
        verticalRulerView = ruler
        hasVerticalRuler = true
        rulersVisible = true

        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(storageChanged), name: NSTextStorage.didProcessEditingNotification, object: buffer.textStorage)
        NotificationCenter.default.addObserver(self, selector: #selector(focusRequested), name: EditorFocus.requested, object: nil)

        ruler.lineIndex = LineIndex(buffer.text)
        restoreViewState()
        highlight(after: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configureTextView() {
        textView.delegate = self
        textView.buffer = buffer
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        // This is code: every automatic substitution and suggestion would corrupt it.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.inlinePredictionType = .no
        textView.writingToolsBehavior = .none
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.font = EditorTheme.font
        textView.defaultParagraphStyle = EditorTheme.paragraphStyle
        textView.typingAttributes = EditorTheme.textAttributes
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.insertionPointColor = .textColor
        // The terminal is a text area to accessibility as well, so UI tests need this to tell them apart.
        textView.setAccessibilityIdentifier("editor.text")
    }

    /// Called when SwiftUI removes the view: remembers where the user was and lets go of the
    /// buffer's storage, which outlives this view.
    func detach() {
        highlightTask?.cancel()
        buffer.savedScrollOrigin = contentView.bounds.origin
        buffer.savedSelection = textView.selectedRanges
        buffer.textStorage.removeLayoutManager(layoutManager)
        NotificationCenter.default.removeObserver(self)
    }

    private func restoreViewState() {
        let length = buffer.textStorage.length
        if let selection = buffer.savedSelection {
            let valid = selection.map(\.rangeValue).filter { NSMaxRange($0) <= length }
            if !valid.isEmpty { textView.selectedRanges = valid.map(NSValue.init(range:)) }
        }
        if let origin = buffer.savedScrollOrigin {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                textView.scroll(origin)
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Deferred a turn: SwiftUI may still be swapping out the view that had the keyboard.
        DispatchQueue.main.async { [weak self] in self?.takeFocusIfRequested() }
    }

    @objc private func focusRequested() {
        takeFocusIfRequested()
    }

    private func takeFocusIfRequested() {
        guard let window, window.isKeyWindow, window.attachedSheet == nil,
              EditorFocus.claim(buffer.url) else { return }
        window.makeFirstResponder(textView)
    }

    /// A horizontally resizable text view only grows when it lays out text, so pin its minimum to the
    /// visible area or it stays at the zero width it was created with.
    override func tile() {
        super.tile()
        let visible = contentView.bounds.size
        if textView.minSize != visible {
            textView.minSize = visible
            textView.sizeToFit()
        }
    }

    @objc private func boundsChanged() {
        ruler.needsDisplay = true
    }

    @objc private func storageChanged(_ notification: Notification) {
        guard buffer.textStorage.editedMask.contains(.editedCharacters) else { return }
        editCount += 1
        ruler.lineIndex = LineIndex(buffer.text)
        highlight(after: Self.highlightDelay)
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        buffer.undoManager
    }

    /// Highlighting only ever touches temporary attributes, never the text, so the caret, selection
    /// and scroll position are left alone. A result for text that has changed since is dropped.
    private func highlight(after delay: Duration) {
        highlightTask?.cancel()
        guard let grammar = buffer.grammar else { return }
        let edit = editCount
        highlightTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let text = self?.buffer.text else { return }
            let runs = await SyntaxHighlighter.shared.runs(for: text, grammar: grammar)
            guard let self, !Task.isCancelled, self.editCount == edit else { return }
            self.apply(runs ?? [], length: (text as NSString).length)
        }
    }

    private func apply(_ runs: [HighlightRun], length: Int) {
        guard length == buffer.textStorage.length else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: length))
        for run in runs where run.location + run.length <= length {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: EditorTheme.color(for: run.scope), forCharacterRange: run.range)
        }
    }

    /// The smallest UTF-16 range of `old` to replace, and what to put there, to turn it into `new`.
    nonisolated static func changedRange(from old: String, to new: String) -> (NSRange, String) {
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        var prefix = 0
        let limit = min(oldUnits.count, newUnits.count)
        while prefix < limit, oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix] { suffix += 1 }
        // Never split a surrogate pair.
        if prefix > 0, UTF16.isLeadSurrogate(oldUnits[prefix - 1]) { prefix -= 1 }
        if suffix > 0, UTF16.isTrailSurrogate(oldUnits[oldUnits.count - suffix]) { suffix -= 1 }
        let replacement = String(decoding: newUnits[prefix..<(newUnits.count - suffix)], as: UTF16.self)
        return (NSRange(location: prefix, length: oldUnits.count - suffix - prefix), replacement)
    }
}

final class CodeNSTextView: NSTextView {
    weak var buffer: TextBuffer?

    /// The app's File > Save menu sends this to the first responder.
    @IBAction func saveDocument(_ sender: Any?) {
        do {
            try buffer?.save()
        } catch is SaveConflictError {
            // The conflict bar is already on screen and the save changed nothing; without a sound
            // Cmd-S just seems broken.
            NSSound.beep()
        } catch {
            // Shown inline by the editor from the buffer's saveError.
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(saveDocument(_:)) { return buffer?.state == .text }
        return super.validateUserInterfaceItem(item)
    }

    private var indentUnit: String { buffer?.indentation.text ?? "\t" }

    override func insertTab(_ sender: Any?) {
        let selection = selectedRange()
        if selection.length > 0, (string as NSString).substring(with: selection).contains("\n") {
            changeIndentation(outdent: false)
        } else {
            insertText(indentUnit, replacementRange: selection)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        changeIndentation(outdent: true)
    }

    /// A new line starts where the one before it is indented to.
    override func insertNewline(_ sender: Any?) {
        let selection = selectedRange()
        let text = string as NSString
        let lineStart = text.lineRange(for: NSRange(location: selection.location, length: 0)).location
        var end = lineStart
        while end < selection.location, [0x20, 0x09].contains(text.character(at: end)) { end += 1 }
        insertText("\n" + text.substring(with: NSRange(location: lineStart, length: end - lineStart)), replacementRange: selection)
    }

    /// Indents or outdents every line the selection touches by one step, as a single undo step.
    private func changeIndentation(outdent: Bool) {
        let text = string as NSString
        let selection = selectedRange()
        var touched = selection
        // Lines selected whole end at the start of the next one, which is not meant to move.
        if touched.length > 0, text.character(at: NSMaxRange(touched) - 1) == 0x0A { touched.length -= 1 }
        let range = text.lineRange(for: touched)
        let lines = text.substring(with: range).components(separatedBy: "\n")
        let unit = indentUnit
        var removedFromFirst = 0
        let changed = lines.enumerated().map { index, line -> String in
            // The empty string after the last line's newline is not a line of its own.
            if line.isEmpty { return line }
            guard outdent else { return unit + line }
            let removed = Self.outdentLength(of: line, unit: unit)
            if index == 0 { removedFromFirst = removed }
            return String(line.dropFirst(removed))
        }
        let replacement = changed.joined(separator: "\n")
        guard replacement != text.substring(with: range) else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: EditorTheme.textAttributes))
        didChangeText()
        breakUndoCoalescing()
        if touched.length == 0 {
            // A caret, or a lone newline at the end of the line, stays on the same character. Indenting
            // put a step before it; outdenting took up to one away.
            let shift = outdent ? -removedFromFirst : (unit as NSString).length
            setSelectedRange(NSRange(location: max(range.location, selection.location + shift), length: selection.length))
        } else {
            let length = (replacement as NSString).length
            let trailing = replacement.hasSuffix("\n") ? 1 : 0
            setSelectedRange(NSRange(location: range.location, length: length - trailing))
        }
    }

    /// One leading tab, or up to one step's worth of leading spaces.
    private static func outdentLength(of line: String, unit: String) -> Int {
        if line.hasPrefix("\t") { return 1 }
        let width = unit == "\t" ? EditorTheme.tabWidth : unit.count
        return line.prefix(width).prefix { $0 == " " }.count
    }

    /// Hosting apps do not always have Find or Save menu items, so their shortcuts are handled here
    /// whenever this view has focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased()
        if flags == [.command], key == "s" {
            saveDocument(nil)
            return true
        }
        let action: NSTextFinder.Action? = switch (flags, key) {
        case ([.command], "f"): .showFindInterface
        case ([.command, .option], "f"): .showReplaceInterface
        case ([.command], "g"): .nextMatch
        case ([.command, .shift], "g"): .previousMatch
        case ([.command], "e"): .setSearchString
        default: nil
        }
        guard let action else { return super.performKeyEquivalent(with: event) }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
        return true
    }
}

/// Line numbers beside a TextKit 1 text view, drawn only for the visible lines.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    var lineIndex = LineIndex("") {
        didSet {
            updateThickness()
            needsDisplay = true
        }
    }

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: nil, orientation: .verticalRuler)
        clientView = textView
        // AppKit no longer clips views by default, and a ruler's dirty rect can reach into the text beside it.
        clipsToBounds = true
        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func updateThickness() {
        let digits = max(3, String(lineIndex.lineCount).count)
        let width = (CGFloat(digits) * EditorTheme.gutterDigitWidth + 20).rounded(.up)
        setThickness(width)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let length = layoutManager.textStorage?.length ?? 0
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let origin = textView.textContainerOrigin
        let attributes: [NSAttributedString.Key: Any] = [.font: EditorTheme.gutterFont, .foregroundColor: NSColor.tertiaryLabelColor]

        var line = lineIndex.line(containing: characterRange.location)
        let starts = lineIndex.starts
        while line < starts.count {
            let start = starts[line]
            if start > NSMaxRange(characterRange) { break }
            let fragment: NSRect
            if start >= length {
                // The empty line after a trailing newline has no glyphs, only the extra fragment.
                fragment = layoutManager.extraLineFragmentRect
                guard fragment.height > 0 else { break }
            } else {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            // Every fragment has the same fixed height with the extra space above the text, so the
            // baseline sits a descent above the bottom. Glyph locations are no use here: TextKit
            // reports a different one for the newline glyph of an empty line.
            let baseline = fragment.height - EditorTheme.font.descender.magnitude
            let y = convert(NSPoint(x: 0, y: fragment.minY + origin.y + baseline), from: textView).y
            if y - EditorTheme.lineHeight > rect.maxY { break }
            let label = String(line + 1) as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: ruleThickness - 10 - size.width, y: y - EditorTheme.gutterFont.ascender - 1), withAttributes: attributes)
            line += 1
        }
    }
}

extension NSRulerView {
    /// The ruler floats over the clip view, whose left edge AppKit places at minus the ruler's width
    /// when the document is first shown, but does not move when the width changes later. Shift it by
    /// the difference, or the first columns of text end up underneath the ruler.
    func setThickness(_ thickness: CGFloat) {
        let delta = thickness - ruleThickness
        guard delta != 0 else { return }
        ruleThickness = thickness
        guard let scrollView else { return }
        scrollView.tile()
        let clip = scrollView.contentView
        clip.setBoundsOrigin(NSPoint(x: clip.bounds.minX - delta, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
    }
}

#if DEBUG
#Preview("Swift") {
    CodeTextView(buffer: .previewSample(url: PreviewSamples.url("Sources/ActivityBadge.swift"), text: PreviewSamples.swiftSource))
        .frame(width: 640, height: 420)
}

#Preview("Swift, Dark") {
    CodeTextView(buffer: .previewSample(url: PreviewSamples.url("Sources/ActivityBadge.swift"), text: PreviewSamples.swiftSource))
        .frame(width: 640, height: 420)
        .preferredColorScheme(.dark)
}

#Preview("JSON") {
    CodeTextView(buffer: .previewSample(url: PreviewSamples.url("package.json"), text: PreviewSamples.jsonSource))
        .frame(width: 640, height: 360)
}

#Preview("JSON, Dark") {
    CodeTextView(buffer: .previewSample(url: PreviewSamples.url("package.json"), text: PreviewSamples.jsonSource))
        .frame(width: 640, height: 360)
        .preferredColorScheme(.dark)
}

#Preview("Markdown") {
    CodeTextView(buffer: .previewSample(url: PreviewSamples.url("README.md"), text: PreviewSamples.markdownSource))
        .frame(width: 640, height: 360)
}

#Preview("Plain Text") {
    CodeTextView(buffer: .previewSample(url: PreviewSamples.url("CHECKLIST"), text: PreviewSamples.plainSource))
        .frame(width: 640, height: 240)
}
#endif
