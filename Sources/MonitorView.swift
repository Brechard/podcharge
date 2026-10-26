import SwiftUI

struct MonitorView: View {
    @ObservedObject var monitor: AirPodsMonitor
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(monitor.deviceName.isEmpty ? "AirPods" : monitor.deviceName)
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text("PODCHARGE")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.bottom, 5)

            Group {
                if let warning = coordinator.chargingWarning {
                    Label(warning.message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("AirPods warning: \(warning.message)")
                } else {
                    Text(monitor.statusText)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)

            VStack(spacing: 0) {
                partRow("Left", symbol: "airpod.left", reading: monitor.left)
                Divider().padding(.leading, 36)
                partRow("Right", symbol: "airpod.right", reading: monitor.right)
                Divider().padding(.leading, 36)
                partRow("Case", symbol: "battery.100", reading: monitor.caseBattery)
            }

            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .accessibilityHidden(true)
                if let seen = monitor.lastAdvertisement {
                    Text("Last signal \(seen.formatted(date: .omitted, time: .standard))")
                } else {
                    Text("No recent AirPods signal")
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .padding(.top, 9)

            Divider().padding(.top, 10).padding(.bottom, 7)

            HStack(spacing: 4) {
                Button("Refresh") { monitor.refresh() }
                    .accessibilityLabel("Refresh AirPods readings")
                Button(coordinator.widgetVisible ? "Hide widget" : "Keep on desktop") {
                    coordinator.toggleWidget()
                }
                Spacer(minLength: 0)
                Button("Quit") { coordinator.quit() }
            }
            .controlSize(.small)

            Text("Local to this Mac · Open the case nearby for charging status")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
        }
        .padding(13)
        .frame(width: 310)
    }

    private func partRow(_ title: String, symbol: String, reading: PartReading) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 27)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Label(chargeText(reading.charging), systemImage: chargeSymbol(reading.charging))
                    .font(.system(size: 10))
                    .foregroundStyle(chargeColor(reading.charging))
                    .labelStyle(.titleAndIcon)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(reading.percent.map { "\(reading.sourceLabel.contains("Bluetooth") && reading.approximate ? "≈" : "")\($0)%" } ?? "—")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(sourceText(reading))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(height: 48)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(reading.percent.map { "\($0) percent" } ?? "percentage unknown"), \(chargeText(reading.charging)), \(sourceText(reading))")
    }

    private func sourceText(_ reading: PartReading) -> String {
        switch reading.sourceLabel {
        case "Nearby Bluetooth estimate": "Bluetooth estimate"
        case "Stale Bluetooth estimate": "Stale Bluetooth"
        case "macOS estimate": "macOS reported (cached)"
        default: reading.sourceLabel
        }
    }

    private func chargeText(_ state: ChargeState) -> String {
        switch state {
        case .charging: "Charging"
        case .notCharging: "Not charging"
        case .unknown: "Charging unknown"
        }
    }

    private func chargeSymbol(_ state: ChargeState) -> String {
        switch state {
        case .charging: "bolt.fill"
        case .notCharging: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    private func chargeColor(_ state: ChargeState) -> Color {
        state == .charging ? .green : .secondary
    }
}
