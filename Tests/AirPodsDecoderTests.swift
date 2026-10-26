import Foundation

@main
struct AirPodsDecoderTests {
    static func packet(status: UInt8 = 0x20, buds: UInt8 = 0x82,
                       caseAndFlags: UInt8 = 0x54, model: UInt8 = 0x24) -> Data {
        var bytes = [UInt8](repeating: 0, count: 29)
        bytes[0...9] = [0x4c, 0x00, 0x07, 0x19, 0x01, model, 0x20,
                       status, buds, caseAndFlags]
        return Data(bytes)
    }

    static func main() {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }
        let date = Date(timeIntervalSince1970: 1_000)
        // Public bytes 7...9 from a fresh Pro 2 USB-C advertisement while the
        // left bud was removed and the right bud remained in the open case.
        // The encrypted suffix is deliberately replaced with zeroes.
        let leftOutRightIn = AirPodsDecoder.decode(packet(status: 0x51, buds: 0x99,
                                                          caseAndFlags: 0x98), at: date)!
        check(leftOutRightIn.left.percent == 95 && leftOutRightIn.right.percent == 95,
              "controlled fixture battery orientation")
        check(leftOutRightIn.left.charging == .notCharging &&
              leftOutRightIn.right.charging == .charging,
              "controlled left out, right in charging state")

        // CAPod's independent Pro 2 USB-C in-case fixture has public bytes
        // 0x53 0xaa 0x98 and identifies the right bud as the charging bud.
        let capod = AirPodsDecoder.decode(packet(status: 0x53, buds: 0xaa,
                                                 caseAndFlags: 0x98), at: date)!
        check(capod.left.charging == .notCharging && capod.right.charging == .charging,
              "CAPod Pro 2 USB-C fixture charging orientation")

        // The same physical setup also emitted a byte-7 bit-5-set frame.
        let oppositeOrientation = AirPodsDecoder.decode(packet(status: 0x31, buds: 0x99,
                                                               caseAndFlags: 0xa8), at: date)!
        check(oppositeOrientation.left.charging == .notCharging &&
              oppositeOrientation.right.charging == .charging,
              "opposite orientation charging flags")

        let normal = AirPodsDecoder.decode(packet(), at: date)!
        check(normal.left.percent == 25, "normal left nibble")
        check(normal.right.percent == 85, "normal right nibble")
        check(normal.caseBattery.percent == 45, "case nibble")
        check(normal.left.charging == .charging, "left independent flag")
        check(normal.right.charging == .notCharging, "right independent flag")
        check(normal.caseBattery.charging == .charging, "case independent flag")
        check(normal.left.approximate && normal.left.updatedAt == date, "public estimate metadata")

        let flipped = AirPodsDecoder.decode(packet(status: 0x00, buds: 0xa3,
                                                   caseAndFlags: 0x16), at: date)!
        check(flipped.left.percent == 100 && flipped.right.percent == 35, "flipped bud order")
        check(flipped.left.charging == .notCharging && flipped.right.charging == .charging,
              "flipped independent charge flags")
        check(flipped.caseBattery.charging == .notCharging, "case flag remains independent")

        let absent = AirPodsDecoder.decode(packet(buds: 0xff, caseAndFlags: 0xff))!
        check(absent.left.percent == nil && absent.left.charging == .unknown, "absent left")
        check(absent.right.percent == nil && absent.right.charging == .unknown, "absent right")
        check(absent.caseBattery.percent == nil && absent.caseBattery.charging == .unknown, "absent case")
        let reserved = AirPodsDecoder.decode(packet(buds: 0xbe, caseAndFlags: 0x5c))!
        check(reserved.left.percent == nil && reserved.right.percent == nil &&
              reserved.caseBattery.percent == nil, "reserved nibbles")

        check(AirPodsDecoder.decode(packet(model: 0x14)) != nil, "Lightning Pro 2 model")
        check(AirPodsDecoder.decode(packet(model: 0x0e)) == nil, "other model rejected")
        var invalid = [UInt8](packet())
        invalid[0] = 0x01
        check(AirPodsDecoder.decode(Data(invalid)) == nil, "non Apple manufacturer rejected")
        invalid = [UInt8](packet())
        invalid[2] = 0x12
        check(AirPodsDecoder.decode(Data(invalid)) == nil, "closed encrypted format rejected")
        invalid = [UInt8](packet())
        invalid[3] = 0x11
        check(AirPodsDecoder.decode(Data(invalid)) == nil, "unexpected length field rejected")
        invalid = [UInt8](packet())
        invalid[4] = 0x00
        check(AirPodsDecoder.decode(Data(invalid)) == nil, "pairing mode rejected")
        check(AirPodsDecoder.decode(packet().dropLast()) == nil, "truncated packet rejected")

        let before = AirPodsDecoder.expiring(normal.left, at: date.addingTimeInterval(45))
        check(before.charging == .charging, "45 second boundary remains fresh")
        let after = AirPodsDecoder.expiring(normal.left, at: date.addingTimeInterval(46))
        check(after.charging == .unknown && after.percent == 25, "stale charge expires")
        check(after.sourceLabel == "Stale Bluetooth estimate", "stale source visible")
        let os = PartReading(percent: 90, charging: .unknown, updatedAt: nil,
                             approximate: true, sourceLabel: "macOS estimate")
        check(AirPodsDecoder.expiring(os, at: date.addingTimeInterval(100)) .sourceLabel == "macOS estimate",
              "OS estimate has no BLE expiry")
        print("AirPodsDecoderTests: \(count) checks passed")
    }
}
