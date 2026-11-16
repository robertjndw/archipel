import SwiftUI

/// One result in a type-to-search sheet such as Add Worktree or Switch Branch.
struct SearchResultRow: View {
    let symbol: String
    let title: Text
    let detail: String
    /// Draws the detail in red, for a row that cannot be used as typed.
    var detailIsWarning = false
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            title
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(detail)
                .font(.callout)
                .foregroundStyle(detailStyle)
                .lineLimit(1)
                // The branch name is the part worth truncating.
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(maxHeight: .infinity)
        .background {
            if isSelected {
                // Full accent like Open Quickly, since this is the row Return acts on.
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.tint)
            }
        }
    }

    private var detailStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white.opacity(0.85)) }
        return detailIsWarning ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)
    }
}

extension Text {
    /// Bolds and tints the characters a fuzzy match hit. Built per run so long names don't create one
    /// Text per letter. `onAccent` skips the tint, which would disappear on a selected row's accent fill.
    static func highlighting(_ string: String, matches: [Int], onAccent: Bool) -> Text {
        let matches = Set(matches)
        guard !matches.isEmpty else { return Text(string) }
        var result = AttributedString()
        var run = ""
        var runMatches = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            if runMatches {
                piece.inlinePresentationIntent = .stronglyEmphasized
                if !onAccent { piece.foregroundColor = .accentColor }
            }
            result += piece
            run = ""
        }
        for (index, character) in string.enumerated() {
            let isMatch = matches.contains(index)
            if isMatch != runMatches { flush() }
            runMatches = isMatch
            run.append(character)
        }
        flush()
        return Text(result)
    }
}
