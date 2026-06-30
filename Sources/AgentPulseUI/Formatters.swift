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
        guard let count else { return "0 token" }
        if count >= 100_000_000 {
            return String(format: "%.2f亿 token", Double(count) / 100_000_000)
        }
        if count >= 10_000 {
            return String(format: "%.2f万 token", Double(count) / 10_000)
        }
        return "\(count) token"
    }

    public static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
