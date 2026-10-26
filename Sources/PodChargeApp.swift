import AppKit
import Combine
import SwiftUI

@MainActor
@main
enum PodChargeApplication {
    // NSApplication does not retain its delegate.
    private static var coordinator: AppCoordinator?

    static func main() {
        saveLaunchTargetArguments(ProcessInfo.processInfo.arguments)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let coordinator = AppCoordinator()
        self.coordinator = coordinator
        application.delegate = coordinator
        application.run()
    }

    private static func saveLaunchTargetArguments(_ arguments: [String]) {
        var name: String?
        var address: String?
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if (argument == "--target-name" || argument == "--target-address"),
               index + 1 < arguments.count {
                let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && !value.hasPrefix("--") {
                    if argument == "--target-name" { name = value } else { address = value }
                    index += 1
                }
            }
            index += 1
        }

        let defaults = UserDefaults.standard
        if let name {
            defaults.set(name, forKey: "TargetName")
            if address == nil { defaults.removeObject(forKey: "TargetAddress") }
        }
        if let address { defaults.set(address, forKey: "TargetAddress") }
    }
}

@MainActor
final class AppCoordinator: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    @Published private(set) var widgetVisible = false
    @Published private(set) var chargingWarning: ChargingWarning.Side?

    let monitor: AirPodsMonitor
    private let defaults = UserDefaults.standard
    private let widgetVisibleKey = "WidgetVisible"
    private let widgetFrameKey = "WidgetFrame"
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var widget: NSPanel?
    private var warningEvaluator = ChargingWarning()
    private var warningObservation: AnyCancellable?
    private var warningTimer: Timer?

    override init() {
        monitor = AirPodsMonitor(
            targetName: UserDefaults.standard.string(forKey: "TargetName"),
            targetAddress: UserDefaults.standard.string(forKey: "TargetAddress")
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            updateStatusIcon(on: button)
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 310, height: 292)
        popover.contentViewController = NSHostingController(rootView: MonitorView(monitor: monitor, coordinator: self))
        self.popover = popover

        warningObservation = monitor.$left.combineLatest(monitor.$right).sink { [weak self] _, _ in
            // The monitor publishes each bud separately; read after its frame update finishes.
            DispatchQueue.main.async { [weak self] in self?.evaluateChargingWarning() }
        }
        warningTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateChargingWarning() }
        }
        monitor.start()

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--show-widget") || defaults.bool(forKey: widgetVisibleKey) {
            showWidget()
        } else if arguments.contains("--show-panel") {
            DispatchQueue.main.async { [weak self] in self?.showPopover() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        warningTimer?.invalidate()
        warningTimer = nil
        warningObservation?.cancel()
        warningObservation = nil
    }

    private func evaluateChargingWarning() {
        let next = warningEvaluator.evaluate(left: monitor.left, right: monitor.right, at: Date())
        guard next != chargingWarning else { return }
        chargingWarning = next
        if let button = statusItem?.button { updateStatusIcon(on: button) }
    }

    private func updateStatusIcon(on button: NSStatusBarButton) {
        let base = NSImage(systemSymbolName: "airpodspro", accessibilityDescription: "AirPods")
        if chargingWarning == nil {
            base?.isTemplate = true
            button.image = base
        } else {
            let image = NSImage(size: NSSize(width: 22, height: 20), flipped: false) { _ in
                base?.withSymbolConfiguration(.init(paletteColors: [.labelColor]))?
                    .draw(in: NSRect(x: 1, y: 1, width: 18, height: 18))
                let badgeDiameter: CGFloat = 9 * 1.3
                let badgeRect = NSRect(x: 22 - badgeDiameter, y: 0,
                                       width: badgeDiameter, height: badgeDiameter)
                NSColor.systemOrange.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()
                let mark = NSAttributedString(string: "!", attributes: [
                    .font: NSFont.systemFont(ofSize: 8 * 1.3, weight: .bold),
                    .foregroundColor: NSColor.white
                ])
                let markSize = mark.size()
                mark.draw(at: NSPoint(x: badgeRect.midX - markSize.width / 2,
                                     y: badgeRect.midY - markSize.height / 2))
                return true
            }
            image.isTemplate = false
            button.image = image
        }
        if base == nil { button.title = "◉" }
        button.toolTip = chargingWarning.map { "PodCharge · \($0.message)" }
            ?? "PodCharge AirPods battery"
        button.setAccessibilityLabel(chargingWarning.map { "AirPods warning: \($0.message)" }
            ?? "PodCharge AirPods battery")
    }

    @objc private func togglePopover() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button, let popover else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggleWidget() {
        if widgetVisible {
            widget?.close()
        } else {
            showWidget()
        }
    }

    private func showWidget() {
        if widget == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 310, height: 292),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered,
                defer: false
            )
            panel.title = "PodCharge"
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: MonitorView(monitor: monitor, coordinator: self))
            panel.center()
            widget = panel
        }
        if let savedFrame = defaults.string(forKey: widgetFrameKey) {
            widget?.setFrame(NSRectFromString(savedFrame), display: false)
        }
        widget?.makeKeyAndOrderFront(nil)
        widgetVisible = true
        defaults.set(true, forKey: widgetVisibleKey)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === widget else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: widgetFrameKey)
        defaults.set(false, forKey: widgetVisibleKey)
        widgetVisible = false
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === widget else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: widgetFrameKey)
    }

    func quit() {
        NSApp.terminate(nil)
    }
}
