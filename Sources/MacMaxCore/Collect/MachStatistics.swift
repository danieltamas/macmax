import Darwin
import Foundation

/// CPU ticks per core as the kernel counts them. The counters are 32-bit and wrap.
struct CPUTicks: Sendable, Equatable {
    let user: UInt32
    let nice: UInt32
    let system: UInt32
    let idle: UInt32
}

/// Reads the Mach host counters: per-core CPU ticks and virtual memory statistics.
enum MachStatistics {
    /// One `CPUTicks` per logical core, or nil when the kernel call fails.
    static func cpuTicks() -> [CPUTicks]? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        // The kernel allocated this array in our address space; it is ours to free.
        defer { vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)) }
        let stride = Int(CPU_STATE_MAX)
        guard coreCount > 0, Int(infoCount) >= Int(coreCount) * stride else { return nil }
        return (0 ..< Int(coreCount)).map { core in
            func ticks(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[core * stride + Int(state)]) }
            return CPUTicks(user: ticks(CPU_STATE_USER), nice: ticks(CPU_STATE_NICE), system: ticks(CPU_STATE_SYSTEM),
                            idle: ticks(CPU_STATE_IDLE))
        }
    }

    /// Shares of the interval between two tick readings. The counters are 32-bit and wrap, so the
    /// delta is taken modulo 2^32; an interval with no ticks on a core fails the whole reading.
    static func usage(from previous: [CPUTicks], to current: [CPUTicks], at: Date) -> Reading<CPUUsage> {
        guard previous.count == current.count, !current.isEmpty else {
            return .failed(reason: "the core count changed between CPU samples")
        }
        var cores: [CoreUsage] = []
        var sumUser = 0.0, sumSystem = 0.0, sumIdle = 0.0
        for (before, after) in zip(previous, current) {
            let userTicks = Double(after.user &- before.user) + Double(after.nice &- before.nice)
            let systemTicks = Double(after.system &- before.system)
            let idleTicks = Double(after.idle &- before.idle)
            let total = userTicks + systemTicks + idleTicks
            guard total > 0 else { return .failed(reason: "CPU tick counters did not advance") }
            cores.append(CoreUsage(userPercent: userTicks / total * 100, systemPercent: systemTicks / total * 100,
                                   idlePercent: idleTicks / total * 100))
            sumUser += userTicks; sumSystem += systemTicks; sumIdle += idleTicks
        }
        // The total weighs every tick equally, so it is the host's utilization even when cores differ.
        let all = sumUser + sumSystem + sumIdle
        return .ok(CPUUsage(userPercent: sumUser / all * 100, systemPercent: sumSystem / all * 100,
                            idlePercent: sumIdle / all * 100, perCore: cores), source: "host_processor_info", at: at)
    }

    /// The raw VM statistics and the page size they count in.
    struct VMCounters: Sendable {
        let pageSize: UInt64
        let wired, internalPages, purgeable, compressor: UInt64
        let swapins, swapouts: UInt64
    }

    static func vmCounters() -> VMCounters? {
        var stats = vm_statistics64_data_t()
        let expected = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var count = expected
        // The kernel reports how many ints it filled; every counter read below must be inside them.
        let lastCounterEnd = mach_msg_type_number_t((MemoryLayout<vm_statistics64_data_t>.offset(of: \.swapouts) ?? .max) / MemoryLayout<integer_t>.size + 2)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS, count >= lastCounterEnd, let pageSize = Sysctl.unsigned("hw.pagesize"), pageSize > 0 else { return nil }
        return VMCounters(pageSize: pageSize, wired: UInt64(stats.wire_count), internalPages: UInt64(stats.internal_page_count),
                          purgeable: UInt64(stats.purgeable_count), compressor: UInt64(stats.compressor_page_count),
                          swapins: stats.swapins, swapouts: stats.swapouts)
    }

    /// Memory the way Activity Monitor counts it: app memory (anonymous less purgeable) plus
    /// wired plus compressor. The file cache is reclaimable and is not "used".
    static func memory(from counters: VMCounters, physicalBytes: UInt64, at: Date) -> Reading<MemoryUsage> {
        let totalPages = physicalBytes / max(counters.pageSize, 1)
        // Each counter is bounded before any arithmetic, so a garbage value fails instead of trapping on overflow.
        guard physicalBytes > 0, [counters.wired, counters.internalPages, counters.purgeable, counters.compressor]
            .allSatisfy({ $0 <= totalPages }) else {
            return .failed(reason: "host_statistics64 gave memory totals outside physical memory")
        }
        guard counters.internalPages >= counters.purgeable else {
            return .failed(reason: "host_statistics64 reports more purgeable than anonymous pages")
        }
        let app = counters.internalPages - counters.purgeable
        let used = (app + counters.wired + counters.compressor) * counters.pageSize
        let compressed = counters.compressor * counters.pageSize
        let wired = counters.wired * counters.pageSize
        guard used > 0, used <= physicalBytes, wired <= used else {
            return .failed(reason: "host_statistics64 gave memory totals outside physical memory")
        }
        return .ok(MemoryUsage(physicalBytes: physicalBytes, usedBytes: used, wiredBytes: wired, compressedBytes: compressed),
                   source: "host_statistics64", at: at)
    }

    static func pressure(at: Date) -> Reading<MemoryPressure> {
        guard let rawLevel = Sysctl.int32("kern.memorystatus_vm_pressure_level"),
              let level = MemoryPressureLevel(rawValue: Int(rawLevel)),
              let percent = Sysctl.int32("kern.memorystatus_level"), (0 ... 100).contains(percent)
        else { return .failed(reason: "kern.memorystatus_* sysctls did not answer") }
        return .ok(MemoryPressure(level: level, availablePercent: Int(percent)), source: "sysctl kern.memorystatus", at: at)
    }
}
