import Foundation
import IOKit
import IOKit.ps

/// Cumulative disk counters summed over the block storage drivers.
struct DiskCounters: Sendable, Equatable {
    let readBytes, writeBytes, readOperations, writeOperations: UInt64
}

/// Readings that come from the IO registry and the power-source API.
enum IOKitReadings {
    /// Each matching registry entry with its properties and a lookup that also searches its parents.
    /// nil when any entry cannot be read: a partial list would pass for a complete one.
    private static func entries(matching className: String) -> [(properties: [String: Any], inherited: (String) -> Any?)]? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: [(properties: [String: Any], inherited: (String) -> Any?)] = []
        var readable = true
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else { readable = false; continue }
            // Resolved now: the entry is released when this iteration ends.
            let location = IORegistryEntrySearchCFProperty(
                entry, kIOServicePlane, "Physical Interconnect Location" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
            result.append((dictionary, { $0 == "Physical Interconnect Location" ? location : nil }))
        }
        return readable ? result : nil
    }

    private static func counter(_ dictionary: [String: Any], _ key: String) -> UInt64? {
        (dictionary[key] as? NSNumber).flatMap { $0.int64Value >= 0 ? $0.uint64Value : nil }
    }

    /// Totals over the internal drivers: external drives and disk images are not the Mac's own disk.
    /// nil when the registry cannot be read or no internal driver publishes statistics: that is
    /// "failed", not "idle".
    static func diskCounters() -> DiskCounters? {
        guard let drivers = entries(matching: "IOBlockStorageDriver") else { return nil }
        var totals = (read: UInt64(0), write: UInt64(0), readOps: UInt64(0), writeOps: UInt64(0))
        var seen = false
        for driver in drivers where driver.inherited("Physical Interconnect Location") as? String == "Internal" {
            guard let statistics = driver.properties["Statistics"] as? [String: Any],
                  let read = counter(statistics, "Bytes (Read)"), let write = counter(statistics, "Bytes (Write)"),
                  let readOps = counter(statistics, "Operations (Read)"),
                  let writeOps = counter(statistics, "Operations (Write)") else { return nil }
            let sums = (totals.read.addingReportingOverflow(read), totals.write.addingReportingOverflow(write),
                        totals.readOps.addingReportingOverflow(readOps), totals.writeOps.addingReportingOverflow(writeOps))
            guard !sums.0.overflow, !sums.1.overflow, !sums.2.overflow, !sums.3.overflow else { return nil }
            totals = (sums.0.partialValue, sums.1.partialValue, sums.2.partialValue, sums.3.partialValue)
            seen = true
        }
        return seen ? DiskCounters(readBytes: totals.read, writeBytes: totals.write,
                                   readOperations: totals.readOps, writeOperations: totals.writeOps) : nil
    }

    /// The busiest accelerator's "Device Utilization %". `unavailable` when the Mac publishes none.
    static func gpuUtilization(at: Date) -> Reading<Double> {
        guard let accelerators = entries(matching: "IOAccelerator")?.map(\.properties) else {
            return .failed(reason: "the IO registry could not be read for the GPU")
        }
        let values = accelerators.compactMap { accelerator -> Double? in
            guard let statistics = accelerator["PerformanceStatistics"] as? [String: Any],
                  let percent = (statistics["Device Utilization %"] as? NSNumber)?.doubleValue else { return nil }
            return percent
        }
        guard let busiest = values.max() else { return .unavailable(reason: "this Mac publishes no GPU utilization counter") }
        guard (0 ... 100).contains(busiest) else { return .failed(reason: "GPU utilization \(busiest) is outside 0...100") }
        return .ok(busiest, source: "IOAccelerator", at: at)
    }

    /// The first accelerator's model name and core count, as the registry publishes them; either is nil when it does not.
    static func gpuIdentity() -> (name: String?, cores: Int?)? {
        guard let accelerators = entries(matching: "IOAccelerator")?.map(\.properties) else { return nil }
        guard let first = accelerators.first else { return (nil, nil) }
        let name = (first["model"] as? String) ?? (first["model"] as? Data).flatMap { String(data: $0, encoding: .utf8) }
        let cores = (first["gpu-core-count"] as? NSNumber).map(\.intValue)
        return (name?.trimmingCharacters(in: .controlCharacters.union(.whitespaces)), cores)
    }

    static func battery(at: Date) -> Reading<BatteryStatus> {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return .failed(reason: "the power sources could not be read")
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            else { return .failed(reason: "a power source description could not be read") }
            guard description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            guard let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, (1 ... 1_000_000).contains(maximum),
                  let state = description[kIOPSPowerSourceStateKey] as? String,
                  (0 ... maximum).contains(current) else { return .failed(reason: "the battery description is incomplete") }
            guard let isCharging = description[kIOPSIsChargingKey] as? Bool,
                  state == kIOPSACPowerValue || state == kIOPSBatteryPowerValue else {
                return .failed(reason: "the battery description is incomplete")
            }
            return .ok(BatteryStatus(chargePercent: current * 100 / maximum,
                                     powerSource: state == kIOPSACPowerValue ? .ac : .battery, isCharging: isCharging),
                       source: "IOPS", at: at)
        }
        return .unavailable(reason: "this Mac has no internal battery")
    }
}
