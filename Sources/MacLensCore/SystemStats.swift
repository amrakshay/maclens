import Foundation
import Darwin

/// Machine-wide CPU load and memory, from Mach host statistics (no root needed).
public final class SystemStats {
    private var prevTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    public init() {}

    public struct Memory: Sendable, Equatable {
        public var total: Int64
        /// Activity Monitor's "Memory Used" = app memory + wired + compressed.
        public var used: Int64
        public var compressed: Int64
        public var wired: Int64
        public var swapUsed: Int64
    }

    /// Percent of the whole machine (all cores) busy since the previous call; nil on the first call.
    public func cpuLoad() -> Double? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        let now = (UInt64(t.0), UInt64(t.1), UInt64(t.2), UInt64(t.3)) // user, system, idle, nice
        defer { prevTicks = (now.0, now.1, now.2, now.3) }
        guard let p = prevTicks else { return nil }
        let busy = Double((now.0 &- p.user) + (now.1 &- p.system) + (now.3 &- p.nice))
        let total = busy + Double(now.2 &- p.idle)
        return total > 0 ? busy / total * 100 : nil
    }

    public func memory() -> Memory? {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return nil }
        let page = Int64(vm_kernel_page_size)
        let app = (Int64(vm.internal_page_count) - Int64(vm.purgeable_count)) * page
        let wired = Int64(vm.wire_count) * page
        let compressed = Int64(vm.compressor_page_count) * page
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return Memory(total: Int64(ProcessInfo.processInfo.physicalMemory), used: app + wired + compressed,
                      compressed: compressed, wired: wired, swapUsed: Int64(swap.xsu_used))
    }

    public struct Disk: Sendable, Equatable {
        public var total: Int64
        /// Space available for important use (includes purgeable space macOS can free), as Finder reports it.
        public var available: Int64
    }

    public static func disk(_ path: String = "/") -> Disk? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: path).resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let avail = v.volumeAvailableCapacityForImportantUsage else { return nil }
        return Disk(total: Int64(total), available: avail)
    }
}
