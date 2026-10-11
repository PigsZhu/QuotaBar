import Foundation

struct UsageWindow: Sendable {
    let usedPercent: Int
    let resetDate: Date?
    let durationMinutes: Int?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }

    var remainingFraction: Double {
        Double(remainingPercent) / 100
    }

    var title: String {
        switch durationMinutes {
        case 300:
            "5 小时额度"
        case 10_080:
            "每周额度"
        case let minutes? where minutes % 60 == 0:
            "\(minutes / 60) 小时额度"
        case let minutes?:
            "\(minutes) 分钟额度"
        case nil:
            "Codex 额度"
        }
    }
}

struct UsageSnapshot: Sendable {
    let providerName: String
    let planName: String?
    /// The displayed Codex window: five-hour first, otherwise weekly, when available.
    let primary: UsageWindow?
    let updatedAt: Date
}
