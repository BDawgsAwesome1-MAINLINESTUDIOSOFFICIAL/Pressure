import Foundation
import IOKit.ps

struct PowerReading: Equatable {
    enum Mode: Equatable {
        case battery
        case ac
    }

    var mode: Mode
    var percent: Int?
    var isCharging: Bool
    var isLow: Bool
    var onAC: Bool

    var compactText: String {
        if mode == .ac { return "Power" }
        return "\(percent ?? 0)%"
    }

    var title: String {
        mode == .ac ? "Power" : "Battery"
    }

    var detail: String {
        switch mode {
        case .ac:
            return "AC power"
        case .battery:
            if isLow { return "Low battery" }
            if isCharging { return "Charging" }
            if onAC { return "Charged" }
            return "On battery"
        }
    }

    var symbolName: String {
        switch mode {
        case .ac:
            return "powerplug.fill"
        case .battery:
            if isCharging { return "bolt.fill" }
            if (percent ?? 100) <= 10 { return "battery.0" }
            if (percent ?? 100) <= 25 { return "battery.25" }
            if (percent ?? 100) <= 50 { return "battery.50" }
            if (percent ?? 100) <= 75 { return "battery.75" }
            return "battery.100"
        }
    }

    static let acOnly = PowerReading(mode: .ac, percent: nil, isCharging: false, isLow: false, onAC: true)
}

enum PowerReader {
    static func read() -> PowerReading {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return .acOnly
        }
        guard let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return .acOnly
        }

        for source in list {
            guard let raw = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() else { continue }
            let info = raw as? [String: Any] ?? [:]
            let type = info[kIOPSTypeKey as String] as? String
            guard type == (kIOPSInternalBatteryType as String) else { continue }
            if let present = info[kIOPSIsPresentKey as String] as? Bool, present == false { continue }

            let current = number(info[kIOPSCurrentCapacityKey as String])
            let maxCapacity = number(info[kIOPSMaxCapacityKey as String])
            let percent: Int
            if let current, let maxCapacity, maxCapacity > 0 {
                percent = min(100, max(0, Int((Double(current) / Double(maxCapacity) * 100).rounded())))
            } else {
                percent = min(100, max(0, current ?? 0))
            }

            let charging = bool(info[kIOPSIsChargingKey as String])
            let sourceState = info[kIOPSPowerSourceStateKey as String] as? String
            let onAC = sourceState == (kIOPSACPowerValue as String)
            let isCharging = charging || (onAC && percent < 100)
            return PowerReading(
                mode: .battery,
                percent: percent,
                isCharging: isCharging,
                isLow: percent <= 20 && !isCharging,
                onAC: onAC
            )
        }
        return .acOnly
    }

    private static func number(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }
}
