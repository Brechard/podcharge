import Foundation

@main
enum TargetSelectionTests {
    static func device(_ name: String, _ address: String, pid: String = "0x2024") -> TargetSelection.Device {
        TargetSelection.Device(name: name, details: [
            "device_vendorID": "0x004c", "device_productID": pid,
            "device_address": address, "device_batteryLevelLeft": "75%"
        ])!
    }

    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message)
            count += 1
        }
        let own = device("My AirPods Pro", "AA:BB:CC:DD:EE:01")
        let other = device("Other AirPods Pro", "AA:BB:CC:DD:EE:02")
        var selected = TargetSelection(name: nil, address: nil)
        check(selected.update(connected: [own], paired: [])?.name == own.name, "one connected pair bootstraps")
        check(selected.shouldPersistBootstrap, "bootstrap marked for persistence")
        check(selected.update(connected: [], paired: [own]) == nil, "disconnected pair has no fresh OS record")
        check(selected.name == own.name, "selection survives disconnect")
        check(selected.matchesAdvertisement(name: "my airpods pro"), "selected name still matches BLE")
        check(selected.update(connected: [other], paired: [own]) == nil, "other connected pair cannot replace target")
        check(selected.name == own.name, "target name remains fixed")
        check(!selected.matchesAdvertisement(name: other.name), "other BLE name rejected")

        var explicit = TargetSelection(name: own.name, address: own.address)
        check(explicit.name == own.name, "explicit target available without OS snapshot")
        check(explicit.matchesAdvertisement(name: own.name), "explicit target can scan before snapshot")
        check(explicit.update(connected: [other], paired: []) == nil, "explicit address blocks other pair")
        check(explicit.name == own.name, "missing selected OS record retains target")

        var noBootstrap = TargetSelection(name: nil, address: nil)
        check(noBootstrap.update(connected: [own, other], paired: []) == nil, "multiple connections do not bootstrap")
        check(noBootstrap.name == nil, "no arbitrary selection")
        var duplicateNames = TargetSelection(name: own.name, address: nil)
        let secondSameName = device(own.name, other.address!)
        check(duplicateNames.update(connected: [own], paired: [secondSameName]) == nil,
              "duplicate paired names suppress OS attribution")
        check(duplicateNames.ambiguous, "duplicate name marked ambiguous")
        check(!duplicateNames.matchesAdvertisement(name: own.name), "ambiguous BLE suppressed")
        var addressedDuplicate = TargetSelection(name: own.name, address: own.address)
        check(addressedDuplicate.update(connected: [own], paired: [secondSameName]) == nil,
              "Classic address cannot disambiguate same-name BLE frames")
        check(addressedDuplicate.ambiguous, "addressed duplicate remains ambiguous")

        check(TargetSelection.Device(name: "Wrong vendor", details: [
            "device_vendorID": "0x0001", "device_productID": "0x2024"]) == nil, "vendor gate")
        check(TargetSelection.Device(name: "Wrong model", details: [
            "device_vendorID": "0x004c", "device_productID": "0x2014"]) == nil, "USB-C model gate")
        var sources = RecentSourceSet()
        let first = UUID(), second = UUID()
        let time = Date(timeIntervalSince1970: 1_000)
        check(sources.observe(first, at: time), "first decoded source accepted")
        check(!sources.observe(second, at: time.addingTimeInterval(1)), "second recent source ambiguous")
        check(sources.isAmbiguous, "simultaneous source ambiguity persists")
        sources.expire(at: time.addingTimeInterval(46))
        check(!sources.isAmbiguous, "old rotating UUID expires")
        check(sources.observe(second, at: time.addingTimeInterval(46)), "remaining source recovers")
        print("TargetSelectionTests: \(count) checks passed")
    }
}
