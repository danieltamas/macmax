import Foundation

/// A cumulative counter read at a monotonic instant (`DispatchTime.now().uptimeNanoseconds`),
/// never wall-clock time: the wall clock can jump, a rate over it would be wrong.
public struct CounterSample: Sendable, Equatable {
    public let value: UInt64
    public let uptimeNanoseconds: UInt64

    public init(value: UInt64, uptimeNanoseconds: UInt64) {
        self.value = value
        self.uptimeNanoseconds = uptimeNanoseconds
    }
}

public struct CPUUsage: Sendable, Equatable {
    /// Shares of all CPU time over the interval, in percent; user + system + idle is 100 plus or minus 1.
    public let userPercent: Double
    public let systemPercent: Double
    public let idlePercent: Double
    public let perCore: [CoreUsage]

    public init(userPercent: Double, systemPercent: Double, idlePercent: Double, perCore: [CoreUsage]) {
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.idlePercent = idlePercent
        self.perCore = perCore
    }
}

public struct CoreUsage: Sendable, Equatable {
    public let userPercent: Double
    public let systemPercent: Double
    public let idlePercent: Double

    public init(userPercent: Double, systemPercent: Double, idlePercent: Double) {
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.idlePercent = idlePercent
    }
}

public struct LoadAverages: Sendable, Equatable {
    public let one: Double
    public let five: Double
    public let fifteen: Double

    public init(one: Double, five: Double, fifteen: Double) {
        self.one = one
        self.five = five
        self.fifteen = fifteen
    }
}

/// Memory as Activity Monitor counts it: `usedBytes` is app memory (anonymous pages less
/// purgeable) plus wired plus what the compressor occupies. File cache is not "used".
public struct MemoryUsage: Sendable, Equatable {
    public let physicalBytes: UInt64
    public let usedBytes: UInt64
    public let wiredBytes: UInt64
    public let compressedBytes: UInt64
    /// Physical memory that is neither used nor wired: file cache and truly free pages.
    public var freeBytes: UInt64 { physicalBytes > usedBytes ? physicalBytes - usedBytes : 0 }
    /// What the compressor occupies as a share of physical memory, in percent.
    public var compressorPercentOfRAM: Double {
        physicalBytes == 0 ? 0 : Double(compressedBytes) / Double(physicalBytes) * 100
    }

    public init(physicalBytes: UInt64, usedBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64) {
        self.physicalBytes = physicalBytes
        self.usedBytes = usedBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
    }
}

public enum MemoryPressureLevel: Int, Sendable, Equatable {
    case normal = 1
    case warning = 2
    case critical = 4
}

public struct MemoryPressure: Sendable, Equatable {
    public let level: MemoryPressureLevel
    /// `kern.memorystatus_level`: the percent of memory the system counts as available.
    public let availablePercent: Int

    public init(level: MemoryPressureLevel, availablePercent: Int) {
        self.level = level
        self.availablePercent = availablePercent
    }
}

public struct SwapUsage: Sendable, Equatable {
    public let totalBytes: UInt64
    public let usedBytes: UInt64
    public let freeBytes: UInt64
    public let encrypted: Bool

    public init(totalBytes: UInt64, usedBytes: UInt64, freeBytes: UInt64, encrypted: Bool) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.encrypted = encrypted
    }
}

public struct DiskIORates: Sendable, Equatable {
    public let readBytesPerSecond: Double
    public let writeBytesPerSecond: Double
    public let readOperationsPerSecond: Double
    public let writeOperationsPerSecond: Double

    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double,
                readOperationsPerSecond: Double, writeOperationsPerSecond: Double) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.readOperationsPerSecond = readOperationsPerSecond
        self.writeOperationsPerSecond = writeOperationsPerSecond
    }
}

public struct DiskSpace: Sendable, Equatable {
    /// Free space as the system counts it for important usage (purgeable space included).
    public let freeBytes: UInt64
    public let totalBytes: UInt64

    public init(freeBytes: UInt64, totalBytes: UInt64) {
        self.freeBytes = freeBytes
        self.totalBytes = totalBytes
    }
}

public enum ThermalState: Int, Sendable, Equatable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3
}

public struct ThermalStatus: Sendable, Equatable {
    public let state: ThermalState
    /// `CPU_Speed_Limit` from `pmset -g therm`: 100 when nothing limits the CPU. Nil when pmset
    /// said nothing about it.
    public let cpuSpeedLimitPercent: Int?

    public init(state: ThermalState, cpuSpeedLimitPercent: Int?) {
        self.state = state
        self.cpuSpeedLimitPercent = cpuSpeedLimitPercent
    }
}

public enum PowerSource: String, Sendable, Equatable {
    case battery
    case ac
}

public struct BatteryStatus: Sendable, Equatable {
    public let chargePercent: Int
    public let powerSource: PowerSource
    public let isCharging: Bool

    public init(chargePercent: Int, powerSource: PowerSource, isCharging: Bool) {
        self.chargePercent = chargePercent
        self.powerSource = powerSource
        self.isCharging = isCharging
    }
}

/// One tick of system readings. Each field is its own `Reading`, so one collector failing never
/// hides the others.
public struct SystemSnapshot: Sendable {
    public let cpu: Reading<CPUUsage>
    public let load: Reading<LoadAverages>
    public let coreCount: Reading<Int>
    public let uptimeSeconds: Reading<Double>
    public let bootTime: Reading<Date>
    public let memory: Reading<MemoryUsage>
    public let pressure: Reading<MemoryPressure>
    public let swap: Reading<SwapUsage>
    public let swapInsPerSecond: Reading<Double>
    public let swapOutsPerSecond: Reading<Double>
    public let diskSpace: Reading<DiskSpace>
    public let diskIO: Reading<DiskIORates>
    public let thermal: Reading<ThermalStatus>
    /// GPU device utilization in percent.
    public let gpuUtilizationPercent: Reading<Double>
    public let battery: Reading<BatteryStatus>

    public init(cpu: Reading<CPUUsage>, load: Reading<LoadAverages>, coreCount: Reading<Int>,
                uptimeSeconds: Reading<Double>, bootTime: Reading<Date>, memory: Reading<MemoryUsage>,
                pressure: Reading<MemoryPressure>, swap: Reading<SwapUsage>,
                swapInsPerSecond: Reading<Double>, swapOutsPerSecond: Reading<Double>,
                diskSpace: Reading<DiskSpace>, diskIO: Reading<DiskIORates>, thermal: Reading<ThermalStatus>,
                gpuUtilizationPercent: Reading<Double>, battery: Reading<BatteryStatus>) {
        self.cpu = cpu
        self.load = load
        self.coreCount = coreCount
        self.uptimeSeconds = uptimeSeconds
        self.bootTime = bootTime
        self.memory = memory
        self.pressure = pressure
        self.swap = swap
        self.swapInsPerSecond = swapInsPerSecond
        self.swapOutsPerSecond = swapOutsPerSecond
        self.diskSpace = diskSpace
        self.diskIO = diskIO
        self.thermal = thermal
        self.gpuUtilizationPercent = gpuUtilizationPercent
        self.battery = battery
    }
}
