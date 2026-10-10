import Darwin
import Foundation

struct MemorySnapshot: Equatable {
    var capturedAt: Date
    var physicalBytes: UInt64
    var availableBytes: UInt64
    var freeBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var appBytes: UInt64
    var cachedBytes: UInt64
    var swapUsedBytes: UInt64
    var swapTotalBytes: UInt64
    /// 0–100, higher means less memory is available. This is
    /// `100 - kern.memorystatus_level`, the kernel's own available-memory percentage,
    /// not "RAM used" from Activity Monitor.
    var pressureScore: Double
    var kernelPressure: KernelPressure

    func displayScore(config: AppConfig) -> Double {
        PressurePolicy.effectiveScore(pressureScore, kernel: kernelPressure, config: config)
    }

    func level(config: AppConfig) -> PressureLevel {
        PressureLevel.resolve(score: displayScore(config: config), config: config)
    }
}

enum MemoryReader {
    static func pressureScore(availablePercent: Int) -> Double {
        Double(100 - min(max(availablePercent, 0), 100))
    }

    static func read(now: Date = Date()) -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return nil
        }
        let page = UInt64(pageSize)
        let physical = ProcessInfo.processInfo.physicalMemory

        var availablePercent: Int32 = 0
        var availableSize = MemoryLayout<Int32>.size
        let levelOK = sysctlbyname(
            "kern.memorystatus_level",
            &availablePercent,
            &availableSize,
            nil,
            0
        ) == 0
        let percent = levelOK ? Int(availablePercent) : fallbackAvailablePercent(stats: stats, physical: physical, page: page)
        let score = pressureScore(availablePercent: percent)
        let availableBytes = physical * UInt64(min(max(percent, 0), 100)) / 100

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        let swapOK = sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0

        return MemorySnapshot(
            capturedAt: now,
            physicalBytes: physical,
            availableBytes: availableBytes,
            freeBytes: UInt64(stats.free_count) * page,
            wiredBytes: UInt64(stats.wire_count) * page,
            compressedBytes: UInt64(stats.compressor_page_count) * page,
            appBytes: UInt64(stats.internal_page_count) * page,
            cachedBytes: UInt64(stats.external_page_count) * page,
            swapUsedBytes: swapOK ? swap.xsu_used : 0,
            swapTotalBytes: swapOK ? swap.xsu_total : 0,
            pressureScore: score,
            kernelPressure: KernelPressure(rawLevel: kernelPressureLevel())
        )
    }

    private static func kernelPressureLevel() -> UInt32 {
        var level: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return 0
        }
        return level
    }

    private static func fallbackAvailablePercent(
        stats: vm_statistics64,
        physical: UInt64,
        page: UInt64
    ) -> Int {
        guard physical > 0 else { return 100 }
        let freeish = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * page
        let percent = Int((freeish * 100) / physical)
        return min(max(percent, 0), 100)
    }
}
