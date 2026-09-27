import Foundation
import IOKit
import Darwin

/// Read-only SMC access (fans, system power). Opening AppleSMC does not require root; writing does, and we never write.
public final class SMC {
    private var conn: io_connect_t = 0

    public init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(conn) }

    struct KeyData {
        struct Vers { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0; var release: UInt16 = 0 }
        struct PLimit { var version: UInt16 = 0, length: UInt16 = 0; var cpu: UInt32 = 0, gpu: UInt32 = 0, mem: UInt32 = 0 }
        struct KeyInfo { var dataSize: UInt32 = 0, dataType: UInt32 = 0; var attributes: UInt8 = 0 }
        var key: UInt32 = 0
        var vers = Vers()
        var pLimit = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    public static var keyDataSize: Int { MemoryLayout<KeyData>.stride }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outSize = MemoryLayout<KeyData>.stride
        let r = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<KeyData>.stride, &output, &outSize)
        return r == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    public func read(_ key: String) -> Double? {
        var input = KeyData()
        input.key = Self.fourCC(key)
        input.data8 = 9 // get key info
        guard let info = call(&input) else { return nil }
        input.keyInfo.dataSize = info.keyInfo.dataSize
        input.data8 = 5 // read bytes
        guard let out = call(&input) else { return nil }
        let size = Int(info.keyInfo.dataSize)
        let b = withUnsafeBytes(of: out.bytes) { Array($0.prefix(max(0, min(32, size)))) }
        guard !b.isEmpty else { return nil }
        switch info.keyInfo.dataType {
        case Self.fourCC("flt "):
            guard b.count >= 4 else { return nil }
            return Double(Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24))
        case Self.fourCC("ui8 "): return Double(b[0])
        case Self.fourCC("ui16"): return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case Self.fourCC("ui32"): return b.count >= 4 ? Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])) : nil
        case Self.fourCC("sp78"): return b.count >= 2 ? Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256 : nil
        case Self.fourCC("fpe2"): return b.count >= 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4 : nil
        default: return nil
        }
    }

    /// Current fan speeds in RPM (empty on fanless Macs).
    public func fanRPMs() -> [Double] {
        guard let n = read("FNum"), n > 0 else { return [] }
        return (0..<Int(n)).compactMap { read("F\($0)Ac") }
    }
}

public struct TempReading: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public let name: String
    public let celsius: Double
}

/// Temperature sensors via the IOHIDEventSystem (same approach as macmon/mactop). No root needed.
/// Uses private-but-stable IOKit symbols resolved with dlsym, so it degrades to "unavailable" if they vanish.
public final class HIDTemperatures {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> OpaquePointer?
    private typealias SetMatchingFn = @convention(c) (OpaquePointer, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (OpaquePointer) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (OpaquePointer, CFString) -> UnsafeRawPointer?
    private typealias CopyEventFn = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?
    private typealias GetFloatFn = @convention(c) (OpaquePointer, Int32) -> Double

    private let copyEvent: CopyEventFn
    private let getFloat: GetFloatFn
    private let services: CFArray
    private let names: [String]

    public init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let c = dlsym(h, "IOHIDEventSystemClientCreate"),
              let m = dlsym(h, "IOHIDEventSystemClientSetMatching"),
              let s = dlsym(h, "IOHIDEventSystemClientCopyServices"),
              let p = dlsym(h, "IOHIDServiceClientCopyProperty"),
              let e = dlsym(h, "IOHIDServiceClientCopyEvent"),
              let f = dlsym(h, "IOHIDEventGetFloatValue") else { return nil }
        let create = unsafeBitCast(c, to: CreateFn.self)
        let setMatching = unsafeBitCast(m, to: SetMatchingFn.self)
        let copyServices = unsafeBitCast(s, to: CopyServicesFn.self)
        let copyProperty = unsafeBitCast(p, to: CopyPropertyFn.self)
        copyEvent = unsafeBitCast(e, to: CopyEventFn.self)
        getFloat = unsafeBitCast(f, to: GetFloatFn.self)

        guard let client = create(kCFAllocatorDefault) else { return nil }
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let svcs = copyServices(client)?.takeRetainedValue() else { return nil }
        services = svcs
        var ns: [String] = []
        for i in 0..<CFArrayGetCount(svcs) {
            let svc = OpaquePointer(CFArrayGetValueAtIndex(svcs, i)!)
            if let raw = copyProperty(svc, "Product" as CFString) {
                let v = Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue()
                ns.append((v as? String) ?? "sensor \(i)")
            } else {
                ns.append("sensor \(i)")
            }
        }
        names = ns
        // The client is intentionally kept alive for the process lifetime (services reference it).
    }

    public func read() -> [TempReading] {
        let tempType: Int64 = 15 // kIOHIDEventTypeTemperature
        var out: [TempReading] = []
        for i in 0..<CFArrayGetCount(services) {
            let svc = OpaquePointer(CFArrayGetValueAtIndex(services, i)!)
            guard let ev = copyEvent(svc, tempType, 0, 0) else { continue }
            let v = getFloat(ev, Int32(tempType << 16))
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(ev)).release()
            if v > 0 && v < 150 { out.append(TempReading(name: names[i], celsius: v)) }
        }
        // Several sensors share a name; keep the hottest per name.
        var best: [String: Double] = [:]
        for r in out { best[r.name] = max(best[r.name] ?? 0, r.celsius) }
        return best.map { TempReading(name: $0.key, celsius: $0.value) }.sorted { $0.name < $1.name }
    }
}

public struct ThermalSummary: Sendable, Equatable {
    public var cpuMaxC: Double?
    public var cpuAvgC: Double?
    public var batteryC: Double?
    public var ssdC: Double?
    public var fanRPMs: [Double] = []
    public var all: [TempReading] = []
    public init() {}

    public static func summarize(_ temps: [TempReading], fans: [Double]) -> ThermalSummary {
        var s = ThermalSummary()
        s.all = temps
        s.fanRPMs = fans
        let cpu = temps.filter { $0.name.localizedCaseInsensitiveContains("tdie") || $0.name.hasPrefix("pACC") || $0.name.hasPrefix("eACC") }
        if !cpu.isEmpty {
            s.cpuMaxC = cpu.map(\.celsius).max()
            s.cpuAvgC = cpu.map(\.celsius).reduce(0, +) / Double(cpu.count)
        }
        s.batteryC = temps.filter { $0.name.localizedCaseInsensitiveContains("battery") }.map(\.celsius).max()
        s.ssdC = temps.filter { $0.name.localizedCaseInsensitiveContains("NAND") }.map(\.celsius).max()
        return s
    }
}
