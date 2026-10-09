import Foundation

/// A complete quota read. Missing windows never inherit data from another account.
struct CodexQuotaSnapshot: Codable {
    enum Plan: String, Codable {
        case free, plus, pro, unknown

        init(_ value: String?) {
            let normalized = value?.lowercased() ?? ""
            switch normalized {
            case "pro", "prolite", "promax": self = .pro
            default: self = Plan(rawValue: normalized) ?? .unknown
            }
        }

        var displayName: String {
            switch self {
            case .free: return "Free"
            case .plus: return "Plus"
            case .pro: return "Pro"
            case .unknown: return ""
            }
        }
    }

    enum WindowKind: String, Codable {
        case fiveHour, weekly, other
    }

    struct Window: Codable {
        let kind: WindowKind
        let remaining: Int?
        let resetsAt: TimeInterval?
    }

    struct Cache: Codable {
        let title: String
        let codexQuota: CodexQuotaSnapshot
    }

    let plan: Plan
    let windows: [Window]

    private static func limits(in payload: [String: Any]) -> [String: Any]? {
        if let byID = payload["rateLimitsByLimitId"] as? [String: Any],
            let codex = byID["codex"] as? [String: Any] {
            return codex
        }
        return payload["rateLimits"] as? [String: Any]
    }

    static func planType(in payload: [String: Any]) -> String? {
        return limits(in: payload)?["planType"] as? String
    }

    init?(payload: [String: Any], accountPlan: String? = nil) {
        guard let limits = Self.limits(in: payload) else { return nil }
        plan = Plan(Self.planType(in: payload) ?? accountPlan)
        var windows: [Window] = []

        for key in ["primary", "secondary"] {
            guard let window = limits[key] as? [String: Any] else { continue }
            let duration = Self.number(window["windowDurationMins"]).map { Int($0) }
            let kind: WindowKind
            switch duration {
            case 300: kind = .fiveHour
            case 10_080: kind = .weekly
            case nil where plan == .plus:
                // Compatibility with older Plus responses that omit the duration.
                kind = key == "primary" ? .fiveHour : .weekly
            default: kind = .other
            }
            guard !(plan == .pro && kind == .fiveHour) else { continue }
            let remaining = Self.number(window["usedPercent"]).map {
                max(0, min(100, 100 - Int($0)))
            }
            windows.append(Window(
                kind: kind,
                remaining: remaining,
                resetsAt: Self.timestamp(window["resetsAt"])
            ))
        }
        // Window identity comes from duration, not its primary/secondary position.
        self.windows = windows.sorted { Self.order($0.kind) < Self.order($1.kind) }
    }

    func hasWindow(_ kind: WindowKind) -> Bool {
        return windows.contains { $0.kind == kind }
    }

    func visibleWindows(showFiveHour: Bool, showWeekly: Bool) -> [Window] {
        let selected = windows.filter {
            switch $0.kind {
            case .fiveHour: return showFiveHour
            case .weekly: return showWeekly
            case .other: return true
            }
        }
        // A saved Plus preference must not hide the only available Pro/Free window.
        return selected.isEmpty ? windows : selected
    }

    func title(showFiveHour: Bool = true, showWeekly: Bool = true, now: Date = Date()) -> String {
        let visible = visibleWindows(showFiveHour: showFiveHour, showWeekly: showWeekly)
        let prefix = "✦ CodeX" + (plan.displayName.isEmpty ? "" : " " + plan.displayName)
        guard !visible.isEmpty else { return prefix + "  额度暂不可用" }
        return visible.map { window in
            let remaining = window.remaining
            let width = 10
            var filled = Int((Double(remaining ?? 0) * Double(width) / 100.0).rounded())
            if let remaining = remaining, remaining > 0 && remaining < 100 {
                filled = max(1, min(width - 1, filled))
            }
            let bar = String(repeating: "▰", count: filled)
                + String(repeating: "▱", count: width - filled)
            let value = remaining.map(String.init) ?? "--"
            let percentage = String(repeating: " ", count: max(0, 3 - value.count)) + value + "%"
            return "\(prefix)  \(bar) \(percentage) ↻ \(Self.countdown(window.resetsAt, now: now))"
        }.joined(separator: "\n")
    }

    private static func order(_ kind: WindowKind) -> Int {
        switch kind {
        case .fiveHour: return 0
        case .weekly: return 1
        case .other: return 2
        }
    }

    private static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value)
        } else {
            number = nil
        }
        guard let result = number, result.isFinite else { return nil }
        return result
    }

    private static func timestamp(_ value: Any?) -> TimeInterval? {
        if let number = number(value) { return number }
        guard let string = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)?.timeIntervalSince1970
    }

    private static func countdown(_ timestamp: TimeInterval?, now: Date) -> String {
        guard let timestamp = timestamp else { return "--" }
        let seconds = max(0, Int(timestamp - now.timeIntervalSince1970))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        return days > 0
            ? String(format: "%dd %02dh", days, hours)
            : String(format: "%dh %02dm", hours, minutes)
    }
}
