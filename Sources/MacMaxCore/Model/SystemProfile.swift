import Foundation

/// What the Mac is made of: read once, since none of it changes while MacMax runs. A field the Mac does not report is
/// nil, never a guess.
public struct HardwareProfile: Sendable, Equatable {
    public let chip: String?
    public let performanceCores: Int?
    public let efficiencyCores: Int?
    public let totalCores: Int?
    public let gpuName: String?
    public let gpuCores: Int?
    public let memoryBytes: UInt64?

    public init(chip: String?, performanceCores: Int?, efficiencyCores: Int?, totalCores: Int?, gpuName: String?,
                gpuCores: Int?, memoryBytes: UInt64?) {
        self.chip = chip
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.totalCores = totalCores
        self.gpuName = gpuName
        self.gpuCores = gpuCores
        self.memoryBytes = memoryBytes
    }

    public static func read() -> HardwareProfile {
        let gpu = IOKitReadings.gpuIdentity()
        return HardwareProfile(
            chip: Sysctl.string("machdep.cpu.brand_string"),
            performanceCores: Sysctl.int32("hw.perflevel0.physicalcpu").map(Int.init),
            efficiencyCores: Sysctl.int32("hw.perflevel1.physicalcpu").map(Int.init),
            totalCores: Sysctl.int32("hw.physicalcpu").map(Int.init),
            gpuName: gpu?.name, gpuCores: gpu?.cores, memoryBytes: Sysctl.unsigned("hw.memsize"))
    }
}

/// The moving part of the same picture, from one tick: how hard each core, the GPU and the memory are working.
public struct SystemLive: Sendable, Equatable {
    /// Busy share of each logical core, 0 to 100.
    public let coreBusyPercent: [Double]
    public let gpuPercent: Double?
    /// What the GPU holds: shared system memory on Apple silicon, video memory on a discrete card.
    public let gpuMemoryUsedBytes: UInt64?
    public let gpuMemoryAllocatedBytes: UInt64?
    public let memoryUsedBytes: UInt64?
    public let memoryTotalBytes: UInt64?
    /// Space macOS would purge on top of the free figure; shown next to it so the tile explains why it is below Finder's.
    public let diskPurgeableBytes: UInt64?

    public init(coreBusyPercent: [Double], gpuPercent: Double?, gpuMemoryUsedBytes: UInt64? = nil,
                gpuMemoryAllocatedBytes: UInt64? = nil, memoryUsedBytes: UInt64?, memoryTotalBytes: UInt64?,
                diskPurgeableBytes: UInt64? = nil) {
        self.coreBusyPercent = coreBusyPercent
        self.gpuPercent = gpuPercent
        self.gpuMemoryUsedBytes = gpuMemoryUsedBytes
        self.gpuMemoryAllocatedBytes = gpuMemoryAllocatedBytes
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.diskPurgeableBytes = diskPurgeableBytes
    }

    /// nil when the CPU read failed: no core list is better than an empty one that reads as an idle Mac.
    init?(_ snapshot: SystemSnapshot) {
        guard let cpu = snapshot.cpu.value, !cpu.perCore.isEmpty else { return nil }
        let gpuMemory = IOKitReadings.gpuMemory()
        self.init(coreBusyPercent: cpu.perCore.map { min(100, max(0, $0.userPercent + $0.systemPercent)) },
                  gpuPercent: snapshot.gpuUtilizationPercent.value,
                  gpuMemoryUsedBytes: gpuMemory?.used, gpuMemoryAllocatedBytes: gpuMemory?.allocated,
                  memoryUsedBytes: snapshot.memory.value?.usedBytes, memoryTotalBytes: snapshot.memory.value?.physicalBytes,
                  diskPurgeableBytes: snapshot.diskSpace.value?.purgeableBytes)
    }

    /// Cores doing real work right now: at or above `threshold` percent.
    public func busyCores(threshold: Double = 25) -> Int { coreBusyPercent.filter { $0 >= threshold }.count }
}
