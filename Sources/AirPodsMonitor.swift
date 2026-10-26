import AppKit
@preconcurrency import CoreBluetooth
import Foundation

@MainActor
final class AirPodsMonitor: NSObject, ObservableObject {
    @Published private(set) var deviceName = "AirPods Pro 2"
    @Published private(set) var left: PartReading = .empty
    @Published private(set) var right: PartReading = .empty
    @Published private(set) var caseBattery: PartReading = .empty
    @Published private(set) var statusText = "Checking connected AirPods…"
    @Published private(set) var bluetoothReady = false
    @Published private(set) var lastAdvertisement: Date?

    private var selection: TargetSelection
    private let pinnedPeripheralID: UUID?
    private var central: CBCentralManager?
    private var tick: Timer?
    private var snapshotInFlight = false
    private var lastSnapshot: Date = .distantPast
    private var started = false
    private var selectedTargetDiscoveryCount = 0
    private var recentSources = RecentSourceSet()
    private var ambiguousAdvertisements = false

    init(targetName: String?, targetAddress: String?) {
        self.selection = TargetSelection(name: targetName, address: targetAddress)
        self.pinnedPeripheralID = targetAddress.flatMap(UUID.init(uuidString:))
        super.init()
        if let name = selection.name { deviceName = name; statusText = "Waiting for selected AirPods signal" }
    }

    func start() {
        guard !started else { return }
        started = true
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
        tick = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.maintenance() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
    }

    func refresh() {
        expireReadings()
        writeStatus()
        guard !snapshotInFlight else { return }
        snapshotInFlight = true
        lastSnapshot = Date()
        Self.runSystemProfiler { [weak self] output in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.snapshotInFlight = false
                self.applySnapshot(output)
            }
        }
    }

    @objc private func woke() {
        // A wake invalidates all live charging bits until a new frame arrives.
        invalidateLiveReadings()
        lastAdvertisement = nil
        refresh()
    }

    private func invalidateLiveReadings() {
        func invalidate(_ reading: PartReading) -> PartReading {
            var value = reading
            value.charging = .unknown
            if value.sourceLabel == "Nearby Bluetooth estimate" {
                value.sourceLabel = "Stale Bluetooth estimate"
            }
            return value
        }
        left = invalidate(left)
        right = invalidate(right)
        caseBattery = invalidate(caseBattery)
    }

    private func maintenance() {
        expireReadings()
        expirePeripheralIDs(at: Date())
        if Date().timeIntervalSince(lastSnapshot) >= 30 { refresh() }
    }

    private func expirePeripheralIDs(at now: Date) {
        recentSources.expire(at: now)
        if ambiguousAdvertisements && !recentSources.isAmbiguous {
            ambiguousAdvertisements = false
            if bluetoothReady {
                statusText = "Waiting for selected AirPods signal"
                scanIfPossible()
                writeStatus()
            }
        }
    }

    private func expireReadings() {
        let now = Date()
        let values = (AirPodsDecoder.expiring(left, at: now),
                      AirPodsDecoder.expiring(right, at: now),
                      AirPodsDecoder.expiring(caseBattery, at: now))
        guard values.0.sourceLabel != left.sourceLabel ||
              values.1.sourceLabel != right.sourceLabel ||
              values.2.sourceLabel != caseBattery.sourceLabel else { return }
        (left, right, caseBattery) = values
        statusText = "Bluetooth reading stale; charging unknown"
        writeStatus()
    }

    private func applySnapshot(_ output: Data?) {
        guard let output, let root = try? JSONSerialization.jsonObject(with: output) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]],
              let section = sections.first else {
            if bluetoothReady {
                statusText = ambiguousAdvertisements ? "Ambiguous Bluetooth devices share this name; charging unknown" :
                    selection.name == nil ? "AirPods selection unavailable" :
                    "macOS device check unavailable; listening for selected AirPods"
                scanIfPossible()
                writeStatus()
            }
            return
        }
        func devices(_ key: String) -> [TargetSelection.Device] {
            let list = section[key] as? [[String: Any]] ?? []
            return list.flatMap { item in
            item.compactMap { key, value in
                guard let details = value as? [String: Any] else { return nil }
                return TargetSelection.Device(name: key, details: details)
            }
            }
        }
        let oldName = selection.name
        let candidate = selection.update(connected: devices("device_connected"),
                                         paired: devices("device_not_connected"))
        if selection.shouldPersistBootstrap, oldName == nil, let name = selection.name {
            UserDefaults.standard.set(name, forKey: "TargetName")
            if let address = selection.address { UserDefaults.standard.set(address, forKey: "TargetAddress") }
        }
        if let name = selection.name { deviceName = name.replacingOccurrences(of: " - Find My", with: "") }
        if selection.ambiguous && bluetoothReady {
            central?.stopScan()
            invalidateLiveReadings()
            statusText = "Cannot distinguish paired AirPods sharing this name"
            writeStatus()
            return
        }
        // Only connected records provide an OS percentage fallback. These may
        // themselves be cached, so they never set a charging state or BLE time.
        if let details = candidate?.details {
            left = mergeSystemEstimate(details["device_batteryLevelLeft"], with: left)
            right = mergeSystemEstimate(details["device_batteryLevelRight"], with: right)
            caseBattery = mergeSystemEstimate(details["device_batteryLevelCase"], with: caseBattery)
        }
        if bluetoothReady && ambiguousAdvertisements {
            statusText = "Ambiguous Bluetooth devices share this name; charging unknown"
        } else if bluetoothReady && lastAdvertisement == nil {
            statusText = selection.name == nil ? "Connect one AirPods Pro 2 to select it" :
                candidate == nil ? "Selected AirPods disconnected; listening for case signal" :
                "Connected; waiting for identifiable Bluetooth broadcast"
        }
        scanIfPossible()
        writeStatus()
    }

    private func mergeSystemEstimate(_ raw: Any?, with current: PartReading) -> PartReading {
        guard let raw = raw as? String,
              let number = Int(raw.filter(\.isNumber)), (0...100).contains(number) else { return current }
        if current.sourceLabel == "Nearby Bluetooth estimate" { return current }
        return PartReading(percent: number, charging: .unknown, updatedAt: nil,
                           approximate: true, sourceLabel: "macOS estimate")
    }

    private func scanIfPossible() {
        guard let central, bluetoothReady, selection.name != nil,
              !selection.ambiguous else { return }
        if !central.isScanning {
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
    }

    private static func runSystemProfiler(completion: @escaping @Sendable (Data?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["-json", "SPBluetoothDataType"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = Pipe()
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timeout.cancel()
                completion(process.terminationStatus == 0 ? data : nil)
            } catch { completion(nil) }
        }
    }

    private func writeStatus() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0].appendingPathComponent("PodCharge")
        guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil else { return }
        func part(_ value: PartReading) -> [String: Any] {
            ["percent": value.percent as Any? ?? NSNull(), "charging": value.charging.rawValue,
             "updatedAt": value.updatedAt.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(),
             "approximate": value.approximate, "source": value.sourceLabel]
        }
        let value: [String: Any] = ["deviceSelected": selection.name != nil,
                                    "bluetoothReady": bluetoothReady,
                                    "bluetoothAuthorization": Self.authorizationLabel(CBManager.authorization),
                                    "selectedTargetDiscoveryCount": selectedTargetDiscoveryCount,
                                    "status": statusText,
                                    "left": part(left), "right": part(right), "case": part(caseBattery),
                                    "lastAdvertisement": lastAdvertisement.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
    }

    private static func authorizationLabel(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .allowedAlways: return "allowed"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
}

extension AirPodsMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            bluetoothReady = central.state == .poweredOn
            if !bluetoothReady {
                central.stopScan()
                invalidateLiveReadings()
                lastAdvertisement = nil
                statusText = central.state == .unauthorized ? "Bluetooth access denied" : "Bluetooth unavailable"
                writeStatus()
            } else {
                refresh()
                scanIfPossible()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let peripheralID = peripheral.identifier
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        Task { @MainActor in
            guard selection.name != nil, !selection.ambiguous else { return }
            if let pinnedPeripheralID {
                guard peripheralID == pinnedPeripheralID else { return }
            } else {
                // Name matching is an estimate of identity, not authentication.
                guard selection.matchesAdvertisement(name: advertisedName) else { return }
            }
            guard let data = manufacturerData,
                  data.count == 29, data[5] == 0x24,
                  let reading = AirPodsDecoder.decode(data) else { return }
            let now = Date()
            expirePeripheralIDs(at: now)
            if !recentSources.observe(peripheralID, at: now) {
                ambiguousAdvertisements = true
                invalidateLiveReadings()
                lastAdvertisement = nil
                statusText = "Ambiguous Bluetooth devices share this name; charging unknown"
                writeStatus()
                return
            }
            selectedTargetDiscoveryCount += 1
            left = reading.left
            right = reading.right
            caseBattery = reading.caseBattery
            lastAdvertisement = Date()
            statusText = "Nearby Bluetooth estimate"
            writeStatus()
        }
    }
}
