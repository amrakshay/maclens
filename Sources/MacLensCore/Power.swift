import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

public struct BatteryInfo: Sendable, Equatable {
    public var hasBattery = false
    public var percent: Int?
    public var isCharging = false
    public var onAC = false
    /// Whole-machine power draw (W) from the battery gas gauge telemetry.
    public var systemLoadW: Double?
    /// Battery flow (W): negative while discharging, positive while charging.
    public var batteryW: Double?
    public var adapterW: Double?
    /// Minutes to empty (on battery) or to full (charging).
    public var minutesRemaining: Int?
    public var temperatureC: Double?
    public init() {}
}

public struct SleepAssertion: Identifiable, Sendable, Hashable {
    public let id: String
    public let pid: Int32
    public let processName: String
    public let type: String
    public let name: String
    public let since: Date?
    /// True for assertion types that keep the system or display from idle-sleeping.
    public let preventsSleep: Bool
}

public enum PowerReader {
    public static func battery() -> BatteryInfo {
        var info = BatteryInfo()

        // Percent / time remaining from the power-source API.
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                      (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                info.hasBattery = true
                if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    info.percent = cur * 100 / max
                }
                info.isCharging = (d[kIOPSIsChargingKey] as? Bool) ?? false
                info.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                let t = info.isCharging ? d[kIOPSTimeToFullChargeKey] as? Int : d[kIOPSTimeToEmptyKey] as? Int
                if let t, t > 0 { info.minutesRemaining = t }
            }
        }

        // Watts and temperature from the smart battery driver (readable without root).
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return info }
        defer { IOObjectRelease(svc) }
        func prop(_ k: String) -> Any? {
            IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        // Registry integers are stored unsigned; negative values (discharge current) arrive as 2^64 - n.
        func num(_ v: Any?) -> Double? {
            guard let n = v as? NSNumber else { return nil }
            return n.uint64Value > UInt64(Int64.max) ? Double(Int64(bitPattern: n.uint64Value)) : n.doubleValue
        }

        // Battery flow from measured current × voltage (+ = charging). The telemetry's BatteryPower field reads
        // negative ("discharging") while the Mac is charging, so it isn't used.
        if let amps = num(prop("InstantAmperage") ?? prop("Amperage")), let volts = num(prop("Voltage")) {
            info.batteryW = amps * volts / 1_000_000
        }
        let tel = prop("PowerTelemetryData") as? [String: Any]
        let adapterIn = num(tel?["SystemPowerIn"]).map { $0 / 1000 }
        let adapterLoss = (num(tel?["AdapterEfficiencyLoss"]) ?? 0) / 1000
        let onAC = (prop("ExternalConnected") as? Bool) ?? info.onAC
        if onAC, let pin = adapterIn, pin > 0 {
            // On power: what the adapter delivers, minus what goes into the battery and adapter losses.
            info.adapterW = pin
            info.systemLoadW = max(0, pin - max(0, info.batteryW ?? 0) - adapterLoss)
        } else if let load = num(tel?["SystemLoad"]), load > 0 {
            info.systemLoadW = load / 1000
        } else if let b = info.batteryW, b < 0 {
            info.systemLoadW = -b
        }
        if let t = num(prop("Temperature")) { info.temperatureC = t / 100 }
        if let ext = prop("ExternalConnected") as? Bool { info.onAC = info.onAC || ext }
        return info
    }

    static let sleepPreventingTypes: Set<String> = [
        "PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep",
        "NoIdleSleepAssertion", "NoDisplaySleepAssertion", "InternalPreventSleep", "InternalPreventDisplaySleep",
    ]

    /// Power assertions by process (what `pmset -g assertions` shows). No root needed.
    public static func assertions() -> [SleepAssertion] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var out: [SleepAssertion] = []
        for (pidNum, list) in d {
            let pid = pidNum.int32Value
            for (i, a) in list.enumerated() {
                let type = a["AssertType"] as? String ?? "?"
                let level = (a["AssertLevel"] as? NSNumber)?.intValue ?? 255
                guard level > 0 else { continue }
                let pname = a["Process Name"] as? String ?? ProcList.path(pid: pid).map(PathUtil.lastComponent) ?? "pid \(pid)"
                out.append(SleepAssertion(
                    id: "\(pid)-\(i)-\(type)", pid: pid, processName: pname, type: type,
                    name: a["AssertName"] as? String ?? "", since: a["AssertStartWhen"] as? Date,
                    preventsSleep: sleepPreventingTypes.contains(type)))
            }
        }
        return out.sorted { ($0.preventsSleep ? 0 : 1, $0.processName) < ($1.preventsSleep ? 0 : 1, $1.processName) }
    }
}

/// Battery health as System Settings → Battery → Battery Health shows it.
public struct BatteryHealth: Sendable, Equatable {
    /// "Maximum Capacity" percent exactly as System Settings reports it (from System Information).
    public var maximumCapacityPercent: Int?
    /// Condition as System Settings words it: "Normal" or "Service Recommended".
    public var condition: String?
    public var cycleCount: Int?
    /// Cycle count the battery is rated for (e.g. 1000).
    public var designCycleCount: Int?
    public var fullChargeCapacity_mAh: Int?
    public var designCapacity_mAh: Int?
    public var needsService: Bool {
        guard let c = condition else { return false }
        return c != "Normal"
    }
    public init() {}
}

extension PowerReader {
    /// Reads battery health without root. `system_profiler` (~0.05 s CPU) supplies Apple's own maximum-capacity figure and
    /// condition; the raw ratios in the registry don't match what System Settings shows, so they aren't used for the percent.
    public static func health() -> BatteryHealth? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        func int(_ k: String) -> Int? {
            (IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
        }
        var h = BatteryHealth()
        h.cycleCount = int("CycleCount")
        h.designCycleCount = int("DesignCycleCount9C")
        h.designCapacity_mAh = int("DesignCapacity")
        h.fullChargeCapacity_mAh = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity")

        if let text = Shell.run("/usr/sbin/system_profiler", ["SPPowerDataType", "-json"]),
           let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
           let items = json["SPPowerDataType"] as? [[String: Any]],
           let info = items.lazy.compactMap({ $0["sppower_battery_health_info"] as? [String: Any] }).first {
            if let s = info["sppower_battery_health_maximum_capacity"] as? String { h.maximumCapacityPercent = Int(s.filter(\.isNumber)) }
            if let c = info["sppower_battery_cycle_count"] as? Int { h.cycleCount = c }
            if let cond = info["sppower_battery_health"] as? String {
                // System Information says "Good" where System Settings says "Normal".
                h.condition = cond == "Good" ? "Normal" : cond
            }
        }
        return h
    }
}
