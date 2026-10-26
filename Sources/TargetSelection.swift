import Foundation

/// Selection survives audio disconnection and temporary profiler failures.
/// The Classic Bluetooth address is used only to match macOS inventory records;
/// CoreBluetooth peripheral UUIDs cannot be derived from it.
struct TargetSelection {
    struct Device {
        let name: String
        let address: String?
        let details: [String: Any]

        init?(name: String, details: [String: Any]) {
            guard Self.hex(details["device_vendorID"] as? String) == 0x004c,
                  Self.hex(details["device_productID"] as? String) == 0x2024 else { return nil }
            self.name = name
            self.address = details["device_address"] as? String
            self.details = details
        }

        private static func hex(_ value: String?) -> Int? {
            guard let value else { return nil }
            return Int(value.replacingOccurrences(of: "0x", with: "", options: .caseInsensitive), radix: 16)
        }
    }

    private(set) var name: String?
    private(set) var address: String?
    private(set) var ambiguous = false
    private let explicit: Bool

    init(name: String?, address: String?) {
        self.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.address = address?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        explicit = self.name != nil || self.address != nil
    }

    /// Returns a connected record only for the selected device. No record means
    /// the selected pair remains eligible for passive BLE scanning.
    mutating func update(connected: [Device], paired: [Device]) -> Device? {
        if name == nil && address == nil {
            // Bootstrap only from one currently connected USB-C Pro 2.
            guard connected.count == 1 else { return nil }
            name = connected[0].name
            address = connected[0].address
        } else if name == nil, let address {
            let matches = (connected + paired).filter { Self.sameAddress($0.address, address) }
            if matches.count == 1 { name = matches[0].name }
        }

        // A Classic address distinguishes OS records, but it does not identify
        // a CoreBluetooth advertisement. Duplicate paired names remain unsafe.
        let sameName = (connected + paired).filter { device in
            name.map { Self.normalized($0) == Self.normalized(device.name) } ?? false
        }
        let identities = Set(sameName.map { device in
            device.address.map { $0.uppercased().filter(\.isHexDigit) }
                ?? Self.normalized(device.name)
        })
        ambiguous = identities.count > 1
        guard !ambiguous else { return nil }
        let connectedMatches = connected.filter(matches)
        return connectedMatches.count == 1 ? connectedMatches[0] : nil
    }

    func matchesAdvertisement(name advertisedName: String?) -> Bool {
        guard !ambiguous, let name, let advertisedName else { return false }
        return Self.normalized(name) == Self.normalized(advertisedName)
    }

    var shouldPersistBootstrap: Bool { !explicit && name != nil }

    static func normalized(_ value: String) -> String {
        value.replacingOccurrences(of: " - Find My", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func matches(_ device: Device) -> Bool {
        let nameMatches = name.map { Self.normalized($0) == Self.normalized(device.name) } ?? true
        let addressMatches = address.map { Self.sameAddress($0, device.address) } ?? true
        return nameMatches && addressMatches
    }

    private static func sameAddress(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.uppercased().filter(\.isHexDigit) == b.uppercased().filter(\.isHexDigit)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Tracks only supported, decoded frames supplied by the caller. Old rotating
/// CoreBluetooth UUIDs leave the window instead of poisoning the whole session.
struct RecentSourceSet {
    private var lastSeen: [UUID: Date] = [:]

    mutating func observe(_ id: UUID, at now: Date) -> Bool {
        expire(at: now)
        lastSeen[id] = now
        return lastSeen.count == 1
    }

    mutating func expire(at now: Date) {
        lastSeen = lastSeen.filter { now.timeIntervalSince($0.value) <= 45 }
    }

    var isAmbiguous: Bool { lastSeen.count > 1 }
}
