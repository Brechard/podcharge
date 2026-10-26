import Foundation

enum ChargeState: String {
    case charging
    case notCharging
    case unknown
}

struct PartReading {
    var percent: Int?
    var charging: ChargeState
    var updatedAt: Date?
    var approximate: Bool
    var sourceLabel: String

    static var empty: PartReading {
        PartReading(percent: nil, charging: .unknown, updatedAt: nil,
                    approximate: false, sourceLabel: "Unavailable")
    }
}
