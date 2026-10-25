import Foundation

/// An app's footprint at the moment of the audit.
public struct AppFootprint: Sendable, Codable, Equatable {
    public let name: String
    public let footprintBytes: UInt64

    public init(name: String, footprintBytes: UInt64) {
        self.name = name
        self.footprintBytes = footprintBytes
    }
}

/// Which Homebrew prefixes exist on this Mac and what architecture the Intel one is.
public struct BrewInstalls: Sendable, Codable, Equatable {
    public let intelPrefixIsX86: Bool
    public let nativePrefixPresent: Bool

    public init(intelPrefixIsX86: Bool, nativePrefixPresent: Bool) {
        self.intelPrefixIsX86 = intelPrefixIsX86
        self.nativePrefixPresent = nativePrefixPresent
    }
}

/// A process running under Rosetta with its last CPU samples, oldest first.
public struct TranslatedProcess: Sendable, Codable, Equatable {
    public let name: String
    public let app: String
    public let cpuSamples: [Double]

    public init(name: String, app: String, cpuSamples: [Double]) {
        self.name = name
        self.app = app
        self.cpuSamples = cpuSamples
    }
}

/// An app's footprint now and one hour ago, with its CPU now.
public struct AppGrowth: Sendable, Codable, Equatable {
    public let name: String
    public let footprintBytes: UInt64
    public let footprintOneHourAgoBytes: UInt64
    public let cpuPercent: Double

    public init(name: String, footprintBytes: UInt64, footprintOneHourAgoBytes: UInt64, cpuPercent: Double) {
        self.name = name
        self.footprintBytes = footprintBytes
        self.footprintOneHourAgoBytes = footprintOneHourAgoBytes
        self.cpuPercent = cpuPercent
    }
}

/// What the identity rules read: the leak verdict (a `LeakVerdict` raw value), the public address and country.
public struct IdentityFacts: Sendable, Codable, Equatable {
    public let verdict: String
    public let vpnConnected: Bool
    public let publicIP: String?
    public let publicCountry: String?

    public init(verdict: String, vpnConnected: Bool, publicIP: String?, publicCountry: String?) {
        self.verdict = verdict
        self.vpnConnected = vpnConnected
        self.publicIP = publicIP
        self.publicCountry = publicCountry
    }
}

/// The public address of the previous stored audit; `unavailable` on the first audit.
public struct PreviousIdentity: Sendable, Codable, Equatable {
    public let publicIP: String
    public let publicCountry: String?

    public init(publicIP: String, publicCountry: String?) {
        self.publicIP = publicIP
        self.publicCountry = publicCountry
    }
}

/// Everything one audit evaluates, already reduced to what the rules compare (see docs/RULES.md, Inputs).
/// Immutable input: the same snapshot always gives the same findings. It holds no argv, cwd, tty or path.
/// Every field defaults to `failed("not collected")`: a builder that forgets a field makes its rule unknown, never
/// healthy. It sets `unavailable` only where it knows this Mac lacks the thing (no Docker, an Intel chip).
public struct AuditSnapshot: Sendable, Codable, Equatable {
    static let notCollected = "not collected"

    /// Epoch seconds the snapshot was taken; rules never read the clock.
    public var timestamp: Int64 = 0
    public var uptimeDays: Measure<Int> = .failed(notCollected)
    public var load5: Measure<Double> = .failed(notCollected)
    public var coreCount: Measure<Int> = .failed(notCollected)
    public var ramBytes: Measure<UInt64> = .failed(notCollected)
    public var cpuIdlePercent: Measure<Double> = .failed(notCollected)
    public var kernelTaskCPU: Measure<Double> = .failed(notCollected)
    public var processCount: Measure<Int> = .failed(notCollected)
    public var zombies: Measure<Int> = .failed(notCollected)
    public var swapUsedGB: Measure<Double> = .failed(notCollected)
    public var swapInsPerSecond: Measure<Double> = .failed(notCollected)
    public var compressorPercent: Measure<Int> = .failed(notCollected)
    public var memoryLevel: Measure<Int> = .failed(notCollected)
    public var claudeSessionAgesDays: Measure<[Int]> = .failed(notCollected)
    public var mcpSidecars: Measure<Int> = .failed(notCollected)
    public var dockerVMCompressedGB: Measure<Double> = .failed(notCollected)
    public var containerCPU: Measure<[NamedValue]> = .failed(notCollected)
    public var daemonResidentMB: Measure<[NamedValue]> = .failed(notCollected)
    public var diskFreePercent: Measure<Int> = .failed(notCollected)
    public var diskIOPS: Measure<Double> = .failed(notCollected)
    public var chromeProcesses: Measure<Int> = .failed(notCollected)
    public var apps: Measure<[AppFootprint]> = .failed(notCollected)
    public var crashReports7d: Measure<Int> = .failed(notCollected)
    public var jetsam7d: Measure<Int> = .failed(notCollected)
    public var launchItems: Measure<Int> = .failed(notCollected)
    public var cpuSpeedLimit: Measure<Int> = .failed(notCollected)
    public var appleSilicon: Measure<Bool> = .failed(notCollected)
    public var brewInstalls: Measure<BrewInstalls> = .failed(notCollected)
    public var translatedProcesses: Measure<[TranslatedProcess]> = .failed(notCollected)
    public var identity: Measure<IdentityFacts> = .failed(notCollected)
    public var previousIdentity: Measure<PreviousIdentity> = .failed(notCollected)
    public var appGrowth: Measure<[AppGrowth]> = .failed(notCollected)
    /// The user marked a VPN as "should be on" (Settings > Audit); off by default.
    public var vpnShouldBeOn = false

    public init() {}
}

extension AppFootprint {
    /// Explicit snake_case keys so the stored JSON also decodes with a plain `JSONDecoder`.
    enum CodingKeys: String, CodingKey {
        case name
        case footprintBytes = "footprint_bytes"
    }
}

extension BrewInstalls {
    /// Explicit snake_case keys so the stored JSON also decodes with a plain `JSONDecoder`.
    enum CodingKeys: String, CodingKey {
        case intelPrefixIsX86 = "intel_prefix_is_x86"
        case nativePrefixPresent = "native_prefix_present"
    }
}

extension TranslatedProcess {
    /// Explicit snake_case keys so the stored JSON also decodes with a plain `JSONDecoder`.
    enum CodingKeys: String, CodingKey {
        case name
        case app
        case cpuSamples = "cpu_samples"
    }
}

extension AppGrowth {
    /// Explicit snake_case keys so the stored JSON also decodes with a plain `JSONDecoder`.
    enum CodingKeys: String, CodingKey {
        case name
        case footprintBytes = "footprint_bytes"
        case footprintOneHourAgoBytes = "footprint_one_hour_ago_bytes"
        case cpuPercent = "cpu_percent"
    }
}

extension IdentityFacts {
    /// Explicit snake_case keys so the stored JSON also decodes with a plain `JSONDecoder`.
    enum CodingKeys: String, CodingKey {
        case verdict
        case vpnConnected = "vpn_connected"
        case publicIP = "public_ip"
        case publicCountry = "public_country"
    }
}

extension PreviousIdentity {
    /// Explicit snake_case keys so the stored JSON also decodes with a plain `JSONDecoder`.
    enum CodingKeys: String, CodingKey {
        case publicIP = "public_ip"
        case publicCountry = "public_country"
    }
}

extension AuditSnapshot {
    /// Explicit snake_case keys so the stored JSON also decodes with a plain `JSONDecoder`.
    enum CodingKeys: String, CodingKey {
        case timestamp
        case uptimeDays = "uptime_days"
        case load5 = "load_5"
        case coreCount = "core_count"
        case ramBytes = "ram_bytes"
        case cpuIdlePercent = "cpu_idle_percent"
        case kernelTaskCPU = "kernel_task_cpu"
        case processCount = "process_count"
        case zombies
        case swapUsedGB = "swap_used_gb"
        case swapInsPerSecond = "swap_ins_per_second"
        case compressorPercent = "compressor_percent"
        case memoryLevel = "memory_level"
        case claudeSessionAgesDays = "claude_session_ages_days"
        case mcpSidecars = "mcp_sidecars"
        case dockerVMCompressedGB = "docker_vm_compressed_gb"
        case containerCPU = "container_cpu"
        case daemonResidentMB = "daemon_resident_mb"
        case diskFreePercent = "disk_free_percent"
        case diskIOPS = "disk_iops"
        case chromeProcesses = "chrome_processes"
        case apps
        case crashReports7d = "crash_reports_7d"
        case jetsam7d = "jetsam_7d"
        case launchItems = "launch_items"
        case cpuSpeedLimit = "cpu_speed_limit"
        case appleSilicon = "apple_silicon"
        case brewInstalls = "brew_installs"
        case translatedProcesses = "translated_processes"
        case identity
        case previousIdentity = "previous_identity"
        case appGrowth = "app_growth"
        case vpnShouldBeOn = "vpn_should_be_on"
    }
}
