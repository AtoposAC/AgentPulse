import Foundation

public enum AgentPulseFormatters {
    public static let currency: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    public static func money(_ value: Decimal?, privacy: Bool) -> String {
        if privacy { return "$•••" }
        guard let value else { return "待确认" }
        return currency.string(from: value as NSDecimalNumber) ?? "$0.00"
    }

    public static func tokens(_ count: Int?) -> String {
        guard let count else { return "0 Token" }
        if count >= 100_000_000 {
            return String(format: "%.2f亿 Token", Double(count) / 100_000_000)
        }
        if count >= 10_000 {
            return String(format: "%.2f万 Token", Double(count) / 10_000)
        }
        return "\(count) Token"
    }

    public static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 {
            return "\(hours)小时 \(minutes)分钟"
        }
        if minutes > 0 {
            return "\(minutes)分钟"
        }
        return "\(total)秒"
    }
}
