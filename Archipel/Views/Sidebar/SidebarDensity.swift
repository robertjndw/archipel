import SwiftUI

extension EnvironmentValues {
    @Entry var sidebarDensity: AppSettings.SidebarDensity = .comfortable
}

/// Every spacing the sidebar varies with its density, in one table so the three sizes stay in
/// proportion to each other.
extension AppSettings.SidebarDensity {
    /// Above and below a worktree row's content. The list adds no gap of its own between rows.
    var rowPadding: CGFloat {
        switch self {
        case .compact: 2
        case .comfortable: 4
        case .spacious: 7
        }
    }

    /// Between a row's title and its second line.
    var lineSpacing: CGFloat {
        switch self {
        case .compact: 0
        case .comfortable: 1
        case .spacious: 3
        }
    }

    var sessionRowHeight: CGFloat {
        switch self {
        case .compact: 20
        case .comfortable: 22
        case .spacious: 26
        }
    }

    var projectIconSize: CGFloat {
        switch self {
        case .compact: 16
        case .comfortable: 18
        case .spacious: 20
        }
    }

    /// Above and below a project header's content, enough to clear the first row's selection
    /// highlight. Always the same on both sides: the system centers the disclosure chevron on the
    /// whole header, so uneven padding would put it out of line with the add button and the name.
    /// The list's own gap between sections already keeps one project apart from the next.
    var projectHeaderPadding: CGFloat {
        switch self {
        case .compact: 3
        case .comfortable: 6
        case .spacious: 8
        }
    }

    /// Compact rows fold the second line into the first: metadata moves to the trailing edge and an
    /// agent's message only shows on hover, since the status glyph already says it is waiting.
    var showsSecondLine: Bool { self != .compact }

    /// Spacious gives a waiting agent's question room to be read without opening the session.
    var messageLineLimit: Int { self == .spacious ? 2 : 1 }
}
