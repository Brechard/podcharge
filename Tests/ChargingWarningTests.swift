import Foundation

@main
enum ChargingWarningTests {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        let start = Date(timeIntervalSince1970: 1_000)
        func time(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }
        func bud(_ percent: Int?, _ state: ChargeState, _ seconds: TimeInterval,
                 source: String = "Nearby Bluetooth estimate") -> PartReading {
            PartReading(percent: percent, charging: state, updatedAt: time(seconds),
                        approximate: true, sourceLabel: source)
        }
        func pair(_ seconds: TimeInterval, left: Int? = 25, right: Int? = 35,
                  leftState: ChargeState = .notCharging,
                  rightState: ChargeState = .charging) -> (PartReading, PartReading) {
            (bud(left, leftState, seconds), bud(right, rightState, seconds))
        }

        var warning = ChargingWarning()
        var readings = pair(0)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(0)) == nil,
              "first low mismatch is quiet")
        readings = pair(14)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(14)) == nil,
              "fresh mismatch before 15 seconds is quiet")
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(15)) == nil,
              "timer cannot mature the same packet")
        readings = pair(15)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(15)) == .left,
              "new frame after 15 seconds warns for left")
        check(warning.warning?.message == "Check left AirPod: not charging", "side-specific message")
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(61)) == nil,
              "stale frame clears active warning")

        warning = ChargingWarning()
        readings = pair(0, left: 80, right: 5)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(0)) == nil,
              "80 percent and low stays quiet")
        readings = pair(20, left: 80, right: 5)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(20)) == nil,
              "80 percent and low never warns")
        readings = pair(21, left: 50, right: 5)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(21)) == nil,
              "50 percent is above warning threshold")

        warning = ChargingWarning()
        readings = pair(0, left: nil)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(0)) == nil,
              "missing percent stays quiet")
        readings = pair(1, leftState: .unknown)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(1)) == nil,
              "unknown charging stays quiet")
        readings = pair(2)
        readings.0.sourceLabel = "Stale Bluetooth estimate"
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(2)) == nil,
              "stale source stays quiet")
        readings = pair(3)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(49)) == nil,
              "BLE readings older than 45 seconds stay quiet")

        warning = ChargingWarning()
        readings = pair(0, leftState: .charging, rightState: .notCharging)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(0)) == nil,
              "opposite side starts quiet")
        readings = pair(15, leftState: .charging, rightState: .notCharging)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(15)) == .right,
              "opposite side warns for right")
        readings = pair(16)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(16)) == nil,
              "side change clears and restarts")
        readings = pair(30)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(30)) == nil,
              "new side does not inherit old duration")
        readings = pair(31)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(31)) == .left,
              "new side warns after its own 15 seconds")
        readings = pair(32, leftState: .charging, rightState: .charging)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(32)) == nil,
              "both charging clears warning")
        readings = pair(33)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(33)) == nil,
              "resolved mismatch restarts duration")
        readings = pair(34, left: 50)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(34)) == nil,
              "crossing the low threshold resets duration")
        readings = pair(35)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(35)) == nil,
              "returning below the threshold starts over")

        warning = ChargingWarning()
        readings = pair(0)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(0)) == nil,
              "long-gap case starts quiet")
        readings = pair(60)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(60)) == nil,
              "new frame after an unobserved stale gap restarts duration")
        readings = pair(75)
        check(warning.evaluate(left: readings.0, right: readings.1, at: time(75)) == .left,
              "sustained reports after gap can warn")

        print("ChargingWarningTests: \(checks) checks passed")
    }
}
