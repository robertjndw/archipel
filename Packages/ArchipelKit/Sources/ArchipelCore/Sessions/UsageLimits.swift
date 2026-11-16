import Foundation

/// A subscription whose rate limits Archipel shows. Usage is per account, not per session.
public enum UsageProvider: String, Codable, CaseIterable, Sendable {
    case claude, codex

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// One rate limit window, such as Claude's 5-hour or weekly limit.
public struct UsageWindow: Codable, Equatable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }

    /// Readings can be hours old. Once the window has reset, what it said no longer applies.
    public func usedPercent(at date: Date) -> Double {
        if let resetsAt, resetsAt <= date { return 0 }
        return usedPercent
    }

    /// How much of the window has passed, 0...1. Nil without a reset time to count back from.
    public func elapsedFraction(at date: Date) -> Double? {
        guard let resetsAt, windowMinutes > 0 else { return nil }
        let length = Double(windowMinutes) * 60
        let remaining = resetsAt.timeIntervalSince(date)
        return min(max(1 - remaining / length, 0), 1)
    }

    /// When the limit runs out if usage keeps the average rate of the window so far. Nil when it lasts
    /// until the reset, or when too little of the window has passed for the rate to mean anything.
    public func projectedExhaustion(at date: Date) -> Date? {
        let used = usedPercent(at: date)
        guard let resetsAt, resetsAt > date, used > 0, let elapsed = elapsedFraction(at: date), elapsed >= 0.05 else {
            return nil
        }
        let start = resetsAt.addingTimeInterval(-Double(windowMinutes) * 60)
        let ratePerSecond = used / date.timeIntervalSince(start)
        let exhaustion = date.addingTimeInterval((100 - used) / ratePerSecond)
        return exhaustion < resetsAt ? exhaustion : nil
    }

    /// "5h", "week", "month": short enough for the status bar.
    public var shortLabel: String {
        let hours = windowMinutes / 60
        let days = hours / 24
        switch windowMinutes {
        case 7 * 24 * 60: return "week"
        case 28 * 24 * 60...31 * 24 * 60: return "month"
        case _ where days >= 1 && hours % 24 == 0: return "\(days)d"
        case _ where hours >= 1: return "\(hours)h"
        default: return "\(windowMinutes)m"
        }
    }

    /// "5-hour", "Weekly", "Monthly": for tooltips and VoiceOver.
    public var longLabel: String {
        switch shortLabel {
        case "week": "Weekly"
        case "month": "Monthly"
        case let label where label.hasSuffix("h"): "\(label.dropLast())-hour"
        case let label where label.hasSuffix("d"): "\(label.dropLast())-day"
        case let label: label
        }
    }
}

/// The latest reading of one provider's limits, shortest window first.
public struct ProviderUsage: Codable, Equatable, Sendable {
    public var provider: UsageProvider
    public var windows: [UsageWindow]
    public var updatedAt: Date

    public init(provider: UsageProvider, windows: [UsageWindow], updatedAt: Date) {
        self.provider = provider
        self.windows = windows.sorted { $0.windowMinutes < $1.windowMinutes }
        self.updatedAt = updatedAt
    }
}
