import Foundation
import IOKit.ps

/// Reads the Mac's battery level (0...1) and charging state.
enum BatteryReader {
    struct Info { let fraction: Double; let charging: Bool; let hasBattery: Bool }

    static func current() -> Info {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else {
            return Info(fraction: 1, charging: false, hasBattery: false)
        }
        for src in list {
            guard let desc = IOPSGetPowerSourceDescription(snap, src)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let cap = desc[kIOPSCurrentCapacityKey as String] as? Int ?? 0
            let maxCap = desc[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let state = desc[kIOPSPowerSourceStateKey as String] as? String ?? ""
            let charging = (desc[kIOPSIsChargingKey as String] as? Bool)
                ?? (state == (kIOPSACPowerValue as String))
            let frac = maxCap > 0 ? Double(cap) / Double(maxCap) : 0
            return Info(fraction: min(1, max(0, frac)), charging: charging, hasBattery: true)
        }
        return Info(fraction: 1, charging: false, hasBattery: false)
    }
}

/// Samples CPU and memory load. CPU is a delta between samples, so call
/// `cpuLoad()` on a steady cadence (one owner — the metrics timer).
final class SystemMetrics {
    private var prevCPU: (used: Double, total: Double)?

    func batteryLevel() -> Double { BatteryReader.current().fraction }

    /// Fraction of CPU time spent non-idle since the previous call (0...1).
    func cpuLoad() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let used = user + system + nice
        let total = used + idle
        defer { prevCPU = (used, total) }
        guard let prev = prevCPU else { return 0 }
        let dUsed = used - prev.used
        let dTotal = total - prev.total
        return dTotal > 0 ? min(1, max(0, dUsed / dTotal)) : 0
    }

    /// Fraction of physical memory in use (0...1).
    func memoryUsed() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pageSize = Double(vm_kernel_page_size)
        let usedBytes = (Double(stats.active_count)
                         + Double(stats.wire_count)
                         + Double(stats.compressor_page_count)) * pageSize
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        return total > 0 ? min(1, max(0, usedBytes / total)) : 0
    }
}
