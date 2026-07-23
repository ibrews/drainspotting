import Foundation

/// Parses `ioreg -arn AppleSmartBattery` (plist XML) into a battery snapshot.
public enum BatterySampler {

    public static func parse(ioregPlistXML: String, capturedAt: Date = Date()) -> BatterySnapshot {
        guard let data = ioregPlistXML.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let array = plist as? [[String: Any]],
              let dict = array.first
        else {
            return BatterySnapshot(capturedAt: capturedAt, percent: nil, isCharging: false,
                                   externalPowerConnected: false, cycleCount: nil,
                                   designCapacitymAh: nil, fullChargeCapacitymAh: nil,
                                   hasBattery: false)
        }

        let percent = dict["CurrentCapacity"] as? Int
        let isCharging = (dict["IsCharging"] as? Bool)
            ?? ((dict["ChargerData"] as? [String: Any])?["IsCharging"] as? Int).map { $0 != 0 }
            ?? false
        let external = (dict["ExternalConnected"] as? Bool) ?? false
        let cycles = dict["CycleCount"] as? Int
        let batteryData = dict["BatteryData"] as? [String: Any]
        let design = (batteryData?["DesignCapacity"] as? Int) ?? (dict["DesignCapacity"] as? Int)
        let full = (batteryData?["FullChargeCapacity"] as? Int) ?? (dict["AppleRawMaxCapacity"] as? Int)

        return BatterySnapshot(
            capturedAt: capturedAt,
            percent: percent,
            isCharging: isCharging,
            externalPowerConnected: external,
            cycleCount: cycles,
            designCapacitymAh: design,
            fullChargeCapacitymAh: full,
            hasBattery: true)
    }

    /// Parses the plain `ioreg -rn AppleSmartBattery` text format as a fallback
    /// (used by tests against captured fixtures).
    public static func parse(ioregText: String, capturedAt: Date = Date()) -> BatterySnapshot {
        func intValue(_ key: String) -> Int? {
            guard let range = ioregText.range(of: "\"\(key)\" = ") else { return nil }
            let rest = ioregText[range.upperBound...].prefix(24)
            let digits = rest.prefix { $0.isNumber || $0 == "-" }
            return Int(digits)
        }
        func boolValue(_ key: String) -> Bool? {
            guard let range = ioregText.range(of: "\"\(key)\" = ") else { return nil }
            let rest = ioregText[range.upperBound...].prefix(8)
            if rest.hasPrefix("Yes") { return true }
            if rest.hasPrefix("No") { return false }
            return nil
        }
        func nestedInt(_ dictKey: String, _ key: String) -> Int? {
            guard let range = ioregText.range(of: "\"\(dictKey)\" = {") else { return nil }
            let rest = ioregText[range.upperBound...]
            guard let end = rest.firstIndex(of: "}") else { return nil }
            let body = rest[..<end]
            guard let kr = body.range(of: "\"\(key)\"=") else { return nil }
            let digits = body[kr.upperBound...].prefix { $0.isNumber || $0 == "-" }
            return Int(digits)
        }

        let hasBattery = ioregText.contains("AppleSmartBattery") || ioregText.contains("CurrentCapacity")
        guard hasBattery else {
            return BatterySnapshot(capturedAt: capturedAt, percent: nil, isCharging: false,
                                   externalPowerConnected: false, cycleCount: nil,
                                   designCapacitymAh: nil, fullChargeCapacitymAh: nil,
                                   hasBattery: false)
        }

        let charging = boolValue("IsCharging") ?? (nestedInt("ChargerData", "IsCharging").map { $0 != 0 } ?? false)
        return BatterySnapshot(
            capturedAt: capturedAt,
            percent: intValue("CurrentCapacity"),
            isCharging: charging,
            externalPowerConnected: boolValue("ExternalConnected") ?? false,
            cycleCount: intValue("CycleCount"),
            designCapacitymAh: nestedInt("BatteryData", "DesignCapacity"),
            fullChargeCapacitymAh: nestedInt("BatteryData", "FullChargeCapacity"),
            hasBattery: true)
    }
}
