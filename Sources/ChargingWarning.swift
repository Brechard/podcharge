import Foundation

/// Tracks a charging mismatch only while both buds have current BLE readings.
struct ChargingWarning {
    enum Side: Equatable {
        case left
        case right

        var message: String {
            switch self {
            case .left: "Check left AirPod: not charging"
            case .right: "Check right AirPod: not charging"
            }
        }
    }

    private struct Candidate {
        var side: Side
        var since: Date
        var leftFrame: Date
        var rightFrame: Date
    }

    private var candidate: Candidate?
    private(set) var warning: Side?

    @discardableResult
    mutating func evaluate(left: PartReading, right: PartReading, at now: Date) -> Side? {
        guard let side = Self.mismatchedSide(left: left, right: right, at: now),
              let leftFrame = left.updatedAt, let rightFrame = right.updatedAt else {
            reset()
            return nil
        }

        guard var candidate, candidate.side == side,
              now >= candidate.since,
              leftFrame >= candidate.leftFrame, rightFrame >= candidate.rightFrame,
              max(leftFrame.timeIntervalSince(candidate.leftFrame),
                  rightFrame.timeIntervalSince(candidate.rightFrame)) <= 45 else {
            self.candidate = Candidate(side: side, since: now,
                                       leftFrame: leftFrame, rightFrame: rightFrame)
            warning = nil
            return nil
        }

        // A timer alone cannot turn an old packet into a sustained observation.
        if leftFrame > candidate.leftFrame && rightFrame > candidate.rightFrame {
            candidate.leftFrame = leftFrame
            candidate.rightFrame = rightFrame
            self.candidate = candidate
            if now.timeIntervalSince(candidate.since) >= 15 { warning = side }
        }
        return warning
    }

    private mutating func reset() {
        candidate = nil
        warning = nil
    }

    private static func mismatchedSide(left: PartReading, right: PartReading,
                                       at now: Date) -> Side? {
        func lowAndFresh(_ reading: PartReading) -> Bool {
            guard let percent = reading.percent, percent < 50,
                  let updatedAt = reading.updatedAt,
                  reading.sourceLabel == "Nearby Bluetooth estimate" else { return false }
            let age = now.timeIntervalSince(updatedAt)
            return (0...45).contains(age)
        }
        guard lowAndFresh(left), lowAndFresh(right) else { return nil }
        switch (left.charging, right.charging) {
        case (.notCharging, .charging): return .left
        case (.charging, .notCharging): return .right
        default: return nil
        }
    }
}
