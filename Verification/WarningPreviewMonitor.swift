// Test-only stand-in for AirPodsMonitor. Never include this file in a production build.
// It publishes simulated low-battery values so the real ChargingWarning evaluator and UI can run.
import Combine
import Foundation

@MainActor
final class AirPodsMonitor: NSObject, ObservableObject {
    @Published private(set) var deviceName = "SIMULATED — Warning preview"
    @Published private(set) var left: PartReading = .empty
    @Published private(set) var right: PartReading = .empty
    @Published private(set) var caseBattery: PartReading = .empty
    @Published private(set) var statusText = "Simulated low-battery data"
    @Published private(set) var lastAdvertisement: Date?

    private var tick: Timer?

    init(targetName: String?, targetAddress: String?) {
        super.init()
        _ = targetName
        _ = targetAddress
    }

    func start() {
        guard tick == nil else { return }
        publishFrame()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.publishFrame() }
        }
    }

    func refresh() {
        publishFrame()
    }

    private func publishFrame() {
        let now = Date()
        left = PartReading(percent: 10, charging: .notCharging, updatedAt: now,
                           approximate: false, sourceLabel: "Nearby Bluetooth estimate")
        right = PartReading(percent: 20, charging: .charging, updatedAt: now,
                            approximate: false, sourceLabel: "Nearby Bluetooth estimate")
        caseBattery = PartReading(percent: 50, charging: .notCharging, updatedAt: now,
                                  approximate: false, sourceLabel: "Simulated reading")
        lastAdvertisement = now
    }
}
