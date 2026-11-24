import ACPKit
import Foundation

/// One button of a permission card.
struct PermissionChoice: Equatable, Identifiable, Sendable {
    enum Role: Equatable, Sendable {
        case allow
        case allowAlways
        case reject
        case other
    }

    var optionId: String
    /// The agent's own name for the option, which is what the button says when there is room.
    var name: String
    /// What the button says when there is not: the name if it is short, else a stand-in. Nil
    /// when the option has no stand-in and belongs in the menu instead.
    var compactTitle: String?
    var role: Role

    var id: String { optionId }

    var accessibilityIdentifier: String {
        switch role {
        case .allow: "chat.permission.allow"
        case .allowAlways: "chat.permission.allowAlways"
        case .reject: "chat.permission.reject"
        case .other: "chat.permission.option"
        }
    }
}

/// How a request's options are laid out. Decided by each option's kind and name alone: the ids
/// differ per agent (`allow-once`, `allow_once`, `once`) and mean nothing to the user.
struct PermissionChoices: Equatable, Sendable {
    /// The default button, answered by Return. Only ever an allow-once option: Return must not
    /// grant something lasting.
    var primary: PermissionChoice?
    /// Shown as a button next to the primary one: the first allow-always option.
    var secondary: [PermissionChoice] = []
    /// Answered by Esc.
    var reject: PermissionChoice?
    /// Further options, which always go in a menu. No agent sent any so far.
    var overflow: [PermissionChoice] = []

    /// Longer names than this do not fit a button next to two others in a narrow pane. Codex's
    /// "Yes, and don't ask again for these files" is the case in point.
    static let maximumCompactTitleLength = 24

    init(options: [PermissionOption]) {
        var rest = options
        func take(_ kinds: PermissionOptionKind...) -> PermissionOption? {
            for kind in kinds {
                if let index = rest.firstIndex(where: { $0.kind == kind }) { return rest.remove(at: index) }
            }
            return nil
        }

        if let option = take(.allowOnce) {
            primary = Self.choice(option, role: .allow, fallback: "Allow")
        }
        if let option = take(.rejectOnce, .rejectAlways) {
            reject = Self.choice(option, role: .reject, fallback: "Don't Allow")
        }
        for option in rest {
            let role: PermissionChoice.Role = switch option.kind {
            case .allowOnce: .allow
            case .allowAlways: .allowAlways
            case .rejectOnce, .rejectAlways: .reject
            case .unknown: .other
            }
            let choice = Self.choice(option, role: role, fallback: nil)
            if role == .allowAlways, secondary.isEmpty {
                secondary.append(choice)
            } else {
                overflow.append(choice)
            }
        }
    }

    var isEmpty: Bool {
        primary == nil && secondary.isEmpty && reject == nil && overflow.isEmpty
    }

    /// The secondary buttons that still fit when room is short.
    var compactSecondary: [PermissionChoice] {
        secondary.filter { $0.compactTitle != nil }
    }

    /// What the menu holds when room is short: the secondary options with long names as well.
    var compactOverflow: [PermissionChoice] {
        secondary.filter { $0.compactTitle == nil } + overflow
    }

    private static func choice(_ option: PermissionOption, role: PermissionChoice.Role, fallback: String?) -> PermissionChoice {
        let name = option.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let isShort = !name.isEmpty && name.count <= maximumCompactTitleLength
        return PermissionChoice(
            optionId: option.optionId,
            name: name.isEmpty ? (fallback ?? option.optionId) : name,
            compactTitle: isShort ? name : fallback,
            role: role
        )
    }
}
