import MacMaxCore
import Observation
import SwiftUI

enum PanelTab: String, CaseIterable, Identifiable {
    case overview = "Overview", apps = "Apps", network = "Network", findings = "Findings", cleanup = "Cleanup", history = "History"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .apps: "square.grid.2x2"
        case .network: "arrow.up.arrow.down"
        case .findings: "exclamationmark.bubble"
        case .cleanup: "trash"
        case .history: "chart.xyaxis.line"
        }
    }
}

/// What a section knows about itself: waiting for its first read, readable, or failed with the collector named.
enum SectionState: Equatable {
    case loading(String)
    case ready
    case failed(collector: String, reason: String)
}

enum TrafficWindow: String, CaseIterable, Identifiable {
    case now = "Now", hour = "1 hour", day = "24 hours"
    var id: String { rawValue }
    var seconds: Int64? { self == .hour ? 3_600 : self == .day ? 86_400 : nil }
}

/// One vital tile. A nil value is "not measured", never zero.
struct Vital: Equatable, Identifiable {
    enum Kind: String { case cpu = "CPU", memory = "Memory", swap = "Swap", disk = "Disk free", netIn = "Download", netOut = "Upload" }
    let kind: Kind
    var value: String
    var detail: String
    var series: [Double]
    /// The severity of a rule that fired on this resource.
    var edge: Severity?
    var id: String { kind.rawValue }
}

struct ProcessLine: Equatable, Identifiable {
    let pid: Int32
    let name: String
    let cpuPercent: Double?
    let footprintBytes: UInt64?
    let isTranslated: Bool
    let commandLine: String?
    /// Start time in microseconds: with the pid it names this process and no later one. Nil means an action is not offered.
    var startUs: Int64?
    var id: Int32 { pid }
}

struct IdentityCard: Equatable {
    var verdict: LeakVerdict
    var publicIP: String?
    var publicCountry: String?
    var ispIP: String?
    var ispCountry: String?
    var vpnName: String?
    var vpnState: String?
    var checkEnabled: Bool
    var reason: String?
    var changeNote: String?
    /// Every connected VPN as "Name: state" (the first one found when none is connected). More than one means MacMax
    /// cannot tell which carries the traffic, so it names none of them in the headline.
    var vpnLines: [String] = []
}

struct InterfaceLine: Equatable, Identifiable {
    let name: String
    /// The kernel name (en0, utun7); nil for the total.
    var bsd: String?
    let inPerSecond: Double
    let outPerSecond: Double
    var id: String { bsd ?? name }
    var isActive: Bool { inPerSecond + outPerSecond > 0 }
}

struct TrafficLine: Equatable, Identifiable {
    let id: String
    let name: String
    let bytesIn: Double
    let bytesOut: Double
}

struct ConnectionLine: Equatable, Identifiable {
    let id: Int
    let text: String
}

/// Everything the panel shows, as plain values. The live app fills it from the sampler and the audit; the
/// screenshots fill it with synthetic data. Views read only this, so both draw the same views.
@MainActor
@Observable
final class PanelModel {
    var tab: PanelTab = .overview
    var config: PanelConfig = .default
    var configProblem: String?
    var samplerNote = "Starting the sampler..."
    var samplerFailed = false

    // Overview
    var vitals: [Vital] = []
    var vitalsState: SectionState = .loading("Reading the system...")
    var identity: IdentityCard?
    var identityState: SectionState = .loading("Reading the network...")
    var topConsumers: [(label: String, app: String, value: String)] = []

    // Audit
    var verdict: Verdict?
    var findings: [Finding] = []
    var unknowns: [UnknownRule] = []
    var auditedAt: Date?
    var auditState: SectionState = .loading("Running the first audit...")
    var auditRunning = false
    var storageNote: String?
    var snoozed: Set<String> = []

    // Apps
    var apps: [AppRow] = []
    var appsState: SectionState = .loading("Reading processes...")
    var sort: AppSort = .cpu
    var filter: AppFilter = .all
    var query = ""
    var shown = AppListing.pageSize
    var expandedApp: String?
    var processes: [String: [ProcessLine]] = [:]

    // Network
    var window: TrafficWindow = .now {
        didSet { if window != oldValue { windowChanged() } }
    }
    /// Set by the live controller: the rows shown must match the chosen window at once, not at the next tick.
    var windowChanged: () -> Void = {}
    var interfaces: [InterfaceLine] = []
    /// What this Mac is made of (read once) and how hard its cores, GPU and memory work this tick.
    var hardware: HardwareProfile?
    var live: SystemLive?
    var traffic: [TrafficLine] = []
    var trafficState: SectionState = .loading("Reading network usage...")
    var connections: [String: [ConnectionLine]] = [:]
    var connectionsLoading: Set<String> = []

    // History
    var historyRange: HistoryRange = .hour {
        didSet {
            guard historyRange != oldValue else { return }
            historySelection = nil
            // The old series belong to the old range: drawing them under the new range's axis would mislabel them.
            history = [:]
            historyApps = [:]
            historyState = .loading("Reading history...")
            historyChanged()
        }
    }
    var history: [HistoryMetric: [HistoryPoint]] = [:]
    var historyApps: [HistoryMetric: [HistoryAppSeries]] = [:]
    var historyState: SectionState = .loading("Reading history...")
    var historySelection: HistorySelection?
    var historyHolders: [HistoryHolder] = []
    var historyHoldersState: SectionState = .ready
    var historyChanged: () -> Void = {}
    var loadHolders: (HistorySelection) -> Void = { _ in }

    // What a press does. The live controller sets these; the screenshots leave them empty.
    var runAudit: () -> Void = {}
    var loadConnections: (String) -> Void = { _ in }
    var snooze: (String) -> Void = { _ in }
    var openSettings: (SettingsPane) -> Void = { _ in }
    /// Set by the panel once it is on screen: `showSettingsWindow:` does nothing from a menu bar item on macOS 14 and later,
    /// the `openSettings` environment action does.
    var showSettingsWindow: () -> Void = { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }

    // Actions
    var actionStates: [String: ActionState] = [:]
    var perform: (PanelAction) -> Void = { _ in }
    var containers: [ContainerLine] = []
    var containersState: SectionState = .ready
    var loadContainers: () -> Void = {}

    // Cleanup
    var cleanupPreview: CleanupPreview?
    var cleanupState: SectionState = .ready
    var cleanupResults: [CleanupResult] = []
    /// What was asked to move, in the order of `cleanupResults`, for the size and the rule of each.
    var cleanupMovedFrom: [CleanupCandidate] = []
    var cleanupMoving = false
    /// How far a cleanup has got: items finished, items in all, and the path being moved.
    var cleanupProgress: (done: Int, total: Int, current: String?)?
    var cleanupLogProblem: String?
    var lastCleanups: [ActionRow] = []
    var scanCleanup: () -> Void = {}
    var moveToTrash: ([CleanupCandidate]) -> Void = { _ in }
    var loadLastCleanups: () -> Void = {}

    // Tidy: leftovers a finding can offer to end
    var tidy: TidyScan?
    var tidyState: SectionState = .ready
    var scanTidy: () -> Void = {}

    // Large folders
    var largeItems: [LargeItem]?
    var largeIncomplete = false
    var largeSkippedPrivate = false
    var largeState: SectionState = .ready
    var scanLarge: () -> Void = {}

    // Background items: launch agents and daemons
    var startupItems: [StartupItem]?
    var startupUnreadable = 0
    var startupState: SectionState = .ready
    /// Counts the scans: only the newest publishes, so a slow older one cannot overwrite what an action just changed.
    var startupGeneration = 0
    var scanStartup: () -> Void = {}
    var setStartupEnabled: (StartupItem, Bool) -> Void = { _, _ in }
    /// What the detail view of a background item shows, by plist path; filled when the row is opened.
    var startupInspections: [String: StartupInspection] = [:]
    var startupInspecting: Set<String> = []
    var inspectStartup: (StartupItem) -> Void = { _ in }

    // Apps: the installed ones, what each left behind (by app path), and the last uninstall
    var installedApps: [InstalledApp]?
    var installedAppsUnreadable = 0
    var installedAppsState: SectionState = .ready
    var appLeftovers: [String: [Leftover]] = [:]
    var leftoversLoading: Set<String> = []
    /// Paths whose size is still being measured: "Measuring..." rather than "unknown".
    var measuringApps: Set<String> = []
    /// Count the scans: only the newest may publish sizes, so an older one cannot overwrite a newer list.
    var installedAppsGeneration = 0
    var leftoversGeneration: [String: Int] = [:]
    /// "app path, newline, leftover path": two apps may share a leftover.
    var measuringLeftovers: Set<String> = []
    var uninstalling: String?
    var uninstallProgress: (done: Int, total: Int, next: String?)?
    var uninstallResults: [CleanupResult] = []
    var uninstalledName: String?
    var uninstallStopping = false
    /// By app path. Absent while it is being read; `.unavailable` is "no record", never "not opened".
    var appLastOpened: [String: Reading<Date>] = [:]
    var scanInstalledApps: () -> Void = {}
    var batteryHealth: Reading<BatteryHealth>?
    var thermalSensors: Reading<ThermalSensors>?
    var readPower: () -> Void = {}
    var readingPower = false
    var loadLeftovers: (InstalledApp) -> Void = { _ in }
    var uninstallApp: (InstalledApp, [Leftover]) -> Void = { _, _ in }

    // Permissions, as macOS answers now
    var fullDiskAccess: PermissionState = .unknown
    var notifications: NotificationAccess = .unknown
    var refreshPermissions: () -> Void = {}
    var requestNotifications: () -> Void = {}

    // Updates: the newest release, where this build stands, and the installer's progress
    var latestRelease: ReleaseInfo?
    var releaseCheck: SectionState = .ready
    var updateState: UpdateState = .idle
    var checkForUpdate: () -> Void = {}
    var installUpdate: () -> Void = {}
    var runningVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0" }
    var buildSource: String? { Bundle.main.infoDictionary?["MacMaxSource"] as? String }
    var standing: Standing { MacMaxRelease.standing(version: runningVersion, source: buildSource, latestTag: latestRelease?.tag) }
    /// The version Update would install; nil unless this is the installed app and it is behind a valid release.
    var updateVersion: String? {
        UpdateOffer.version(standing: standing, installed: UpdateOffer.isInstalledLocation(bundlePath: Bundle.main.bundleURL.path,
                            home: FileManager.default.homeDirectoryForCurrentUser.path), latestTag: latestRelease?.tag)
    }
    /// A newer release exists, even when this copy cannot update itself (a build folder): the header arrow follows it.
    var newerRelease: Bool { standing == .behind }

    // Settings
    var settingsPane: SettingsPane = .general
    /// Nil in the screenshots: edits then change only this model.
    var configStore: ConfigStore?
    var vpnServices: [(name: String, state: String)] = []
    var physicalInterface: String?
    var historyBytes: Int64?
    var clearHistory: () -> Void = {}
    var lastCleared: Date?
    var clearError: String?
    var clearing = false

    /// Applies an edit and saves it as it changes. The store re-reads the file first, so a hand edit survives, and
    /// refuses to touch a file that does not parse: the problem shows under the control instead.
    func change(_ edit: (inout PanelConfig) -> Void) {
        guard let configStore else { edit(&config); return }
        do {
            config = try configStore.update(edit)
            configProblem = nil
        } catch ConfigError.malformed(let reason) {
            configProblem = "\(reason). Nothing was saved; fix or remove ~/.macmax/config.json."
        } catch ConfigError.unwritable(let reason) {
            configProblem = reason
        } catch {
            configProblem = "The setting could not be saved."
        }
    }

    var visibleApps: [AppRow] {
        AppListing.sorted(AppListing.filtered(apps, filter: filter, query: query), by: sort)
    }

    var openFindings: [Finding] { findings.filter { !snoozed.contains($0.ruleID) } }

    func selectHistory(_ selection: HistorySelection) {
        historySelection = selection
        historyHolders = []
        historyHoldersState = .loading("Reading the apps...")
        loadHolders(selection)
    }

    func select(_ tab: PanelTab, sort: AppSort? = nil) {
        withAnimation(Motion.spring) {
            self.tab = tab
            if let sort { self.sort = sort }
        }
        if tab == .history { historyChanged() }
    }
}

/// The words for a verdict, shared by the header chip and the menu bar icon.
extension Verdict {
    var label: String {
        switch self {
        case .ok: "OK"
        case .warn: "WARN"
        case .crit: "CRIT"
        case .unknown: "UNKNOWN"
        }
    }
}

extension Severity {
    var label: String { self == .crit ? "CRIT" : self == .warn ? "WARN" : "INFO" }
}

/// A point picked on a chart: the apps that held that resource then are listed under it.
struct HistorySelection: Equatable {
    let metric: HistoryMetric
    let ts: Int64
}
