import Foundation

/// Decodes only the public, paired-mode proximity frame. The final 16 bytes are
/// encrypted and intentionally ignored. `data` includes Apple's 4c00 company ID.
enum AirPodsDecoder {
    struct Reading {
        let left: PartReading
        let right: PartReading
        let caseBattery: PartReading
    }

    static func decode(_ data: Data, at date: Date = Date()) -> Reading? {
        let bytes = [UInt8](data)
        guard bytes.count == 29,
              bytes[0] == 0x4c, bytes[1] == 0x00,
              bytes[2] == 0x07, bytes[3] == 0x19,
              bytes[4] == 0x01,
              bytes[5] == 0x14 || bytes[5] == 0x24,
              bytes[6] == 0x20 else { return nil }

        // Byte 7 bit 5 changes the order of the two bud nibbles and charge bits.
        // The public protocol exposes only 10% steps; these are estimates.
        let flipped = bytes[7] & 0x20 == 0
        let high = bytes[8] >> 4
        let low = bytes[8] & 0x0f
        let leftNibble = flipped ? high : low
        let rightNibble = flipped ? low : high
        let caseNibble = bytes[9] & 0x0f
        let flags = bytes[9] >> 4

        func reading(_ nibble: UInt8, mask: UInt8) -> PartReading {
            guard let percent = percentage(nibble) else { return .empty }
            return PartReading(percent: percent,
                               charging: flags & mask != 0 ? .charging : .notCharging,
                               updatedAt: date, approximate: true,
                               sourceLabel: "Nearby Bluetooth estimate")
        }
        return Reading(left: reading(leftNibble, mask: flipped ? 0x02 : 0x01),
                       right: reading(rightNibble, mask: flipped ? 0x01 : 0x02),
                       caseBattery: reading(caseNibble, mask: 0x04))
    }

    private static func percentage(_ nibble: UInt8) -> Int? {
        switch nibble {
        case 0...9: return Int(nibble) * 10 + 5
        case 10: return 100
        default: return nil // 0xb...0xe unverified; 0xf absent/unknown
        }
    }

    static func expiring(_ reading: PartReading, at now: Date,
                         after interval: TimeInterval = 45) -> PartReading {
        guard let updated = reading.updatedAt,
              now.timeIntervalSince(updated) > interval,
              reading.sourceLabel == "Nearby Bluetooth estimate" else { return reading }
        return PartReading(percent: reading.percent, charging: .unknown,
                           updatedAt: updated, approximate: reading.approximate,
                           sourceLabel: "Stale Bluetooth estimate")
    }
}
