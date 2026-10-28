import MacMaxCore
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
final class PanelModel: ObservableObject {
    @Published var tab: PanelTab = .overview
    @Published var config: PanelConfig = .default
    @Published var configProblem: String?
    @Published var samplerNote = "Starting the sampler..."
    @Published var samplerFailed = false

    // Overview
    @Published var vitals: [Vital] = []
    @Published var vitalsState: SectionState = .loading("Reading the system...")
    @Published var identity: IdentityCard?
    @Published var identityState: SectionState = .loading("Reading the network...")
    @Published var topConsumers: [(label: String, app: String, value: String)] = []

    // Audit
    @Published var verdict: Verdict?
    @Published var findings: [Finding] = []
    @Published var unknowns: [UnknownRule] = []
    @Published var auditedAt: Date?
    @Published var auditState: SectionState = .loading("Running the first audit...")
    @Published var auditRunning = false
    @Published var storageNote: String?
    @Published var snoozed: Set<String> = []

    // Apps
    @Published var apps: [AppRow] = []
    @Published var appsState: SectionState = .loading("Reading processes...")
    @Published var sort: AppSort = .cpu
    @Published var filter: AppFilter = .all
    @Published var query = ""
    @Published var shown = AppListing.pageSize
    @Published var expandedApp: String?
    @Published var expandedSensorGroup: SensorGroup?
    @Published var processes: [String: [ProcessLine]] = [:]

    // Network
    @Published var window: TrafficWindow = .now {
        didSet { if window != oldValue { windowChanged() } }
    }
    /// Set by the live controller: the rows shown must match the chosen window at once, not at the next tick.
    @Published var windowChanged: () -> Void = {}
    @Published var interfaces: [InterfaceLine] = []
    /// What this Mac is made of (read once) and how hard its cores, GPU and memory work this tick.
    @Published var hardware: HardwareProfile?
    @Published var live: SystemLive?
    @Published var traffic: [TrafficLine] = []
    @Published var trafficState: SectionState = .loading("Reading network usage...")
    @Published var connections: [String: [ConnectionLine]] = [:]
    @Published var connectionsLoading: Set<String> = []

    // History
    @Published var historyRange: HistoryRange = .hour {
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
    @Published var history: [HistoryMetric: [HistoryPoint]] = [:]
    @Published var historyApps: [HistoryMetric: [HistoryAppSeries]] = [:]
    @Published var historyState: SectionState = .loading("Reading history...")
    @Published var historySelection: HistorySelection?
    @Published var historyHolders: [HistoryHolder] = []
    @Published var historyHoldersState: SectionState = .ready
    @Published var historyChanged: () -> Void = {}
    @Published var loadHolders: (HistorySelection) -> Void = { _ in }

    // What a press does. The live controller sets these; the screenshots leave them empty.
    @Published var runAudit: () -> Void = {}
    @Published var loadConnections: (String) -> Void = { _ in }
    @Published var snooze: (String) -> Void = { _ in }
    @Published var openSettings: (SettingsPane) -> Void = { _ in }
    /// Set by the panel once it is on screen: `showSettingsWindow:` does nothing from a menu bar item on macOS 14 and later,
    /// the `openSettings` environment action does.
    @Published var showSettingsWindow: () -> Void = { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }

    // Actions
    @Published var actionStates: [String: ActionState] = [:]
    @Published var perform: (PanelAction) -> Void = { _ in }
    @Published var containers: [ContainerLine] = []
    @Published var containersState: SectionState = .ready
    @Published var loadContainers: () -> Void = {}

    // Cleanup
    @Published var cleanupPreview: CleanupPreview?
    @Published var cleanupState: SectionState = .ready
    @Published var cleanupResults: [CleanupResult] = []
    /// What was asked to move, in the order of `cleanupResults`, for the size and the rule of each.
    @Published var cleanupMovedFrom: [CleanupCandidate] = []
    @Published var cleanupMoving = false
    /// How far a cleanup has got: items finished, items in all, and the path being moved.
    @Published var cleanupProgress: (done: Int, total: Int, current: String?)?
    @Published var cleanupLogProblem: String?
    @Published var lastCleanups: [ActionRow] = []
    @Published var scanCleanup: () -> Void = {}
    @Published var moveToTrash: ([CleanupCandidate]) -> Void = { _ in }
    @Published var loadLastCleanups: () -> Void = {}

    // Tidy: leftovers a finding can offer to end
    @Published var tidy: TidyScan?
    @Published var tidyState: SectionState = .ready
    @Published var scanTidy: () -> Void = {}

    // Large folders
    @Published var largeItems: [LargeItem]?
    @Published var largeIncomplete = false
    @Published var largeSkippedPrivate = false
    @Published var largeState: SectionState = .ready
    @Published var scanLarge: () -> Void = {}

    // Background items: launch agents and daemons
    @Published var startupItems: [StartupItem]?
    @Published var startupUnreadable = 0
    @Published var startupState: SectionState = .ready
    /// Counts the scans: only the newest publishes, so a slow older one cannot overwrite what an action just changed.
    @Published var startupGeneration = 0
    @Published var scanStartup: () -> Void = {}
    @Published var setStartupEnabled: (StartupItem, Bool) -> Void = { _, _ in }
    /// What the detail view of a background item shows, by plist path; filled when the row is opened.
    @Published var startupInspections: [String: StartupInspection] = [:]
    @Published var startupInspecting: Set<String> = []
    @Published var inspectStartup: (StartupItem) -> Void = { _ in }

    // Apps: the installed ones, what each left behind (by app path), and the last uninstall
    @Published var installedAppsAt: Date?
    @Published var installedApps: [InstalledApp]?
    @Published var installedAppsUnreadable = 0
    @Published var installedAppsState: SectionState = .ready
    @Published var appLeftovers: [String: [Leftover]] = [:]
    @Published var leftoversLoading: Set<String> = []
    /// Paths whose size is still being measured: "Measuring..." rather than "unknown".
    @Published var measuringApps: Set<String> = []
    /// Count the scans: only the newest may publish sizes, so an older one cannot overwrite a newer list.
    @Published var installedAppsGeneration = 0
    @Published var leftoversGeneration: [String: Int] = [:]
    /// "app path, newline, leftover path": two apps may share a leftover.
    @Published var measuringLeftovers: Set<String> = []
    @Published var uninstalling: String?
    @Published var uninstallProgress: (done: Int, total: Int, next: String?)?
    @Published var uninstallResults: [CleanupResult] = []
    @Published var uninstalledName: String?
    @Published var uninstallStopping = false
    /// By app path. Absent while it is being read; `.unavailable` is "no record", never "not opened".
    @Published var appLastOpened: [String: Reading<Date>] = [:]
    @Published var scanInstalledApps: () -> Void = {}
    @Published var batteryHealth: Reading<BatteryHealth>?
    @Published var batteryStatus: Reading<BatteryStatus>?
    @Published var thermalSensors: Reading<ThermalSensors>?
    @Published var readPower: () -> Void = {}
    /// When the read in flight started; nil when none is. A read that hangs (a sensor call across sleep) is abandoned after a while.
    @Published var readingPowerSince: Date?
    @Published var loadLeftovers: (InstalledApp) -> Void = { _ in }
    @Published var uninstallApp: (InstalledApp, [Leftover]) -> Void = { _, _ in }

    // Old downloads: what sits in Downloads past the chosen age, and the last move
    @Published var oldDownloads: [OldDownload]?
    @Published var oldDownloadsState: SectionState = .ready
    @Published var oldDownloadsDays = OldDownloads.defaultDays
    @Published var oldDownloadsMoving = false
    @Published var oldDownloadsProgress: (done: Int, total: Int, next: String?)?
    @Published var oldDownloadsResults: [CleanupResult] = []
    @Published var scanOldDownloads: () -> Void = {}
    @Published var moveOldDownloads: ([OldDownload]) -> Void = { _ in }

    // Permissions, as macOS answers now
    @Published var fullDiskAccess: PermissionState = .unknown
    @Published var notifications: NotificationAccess = .unknown
    @Published var refreshPermissions: () -> Void = {}
    @Published var requestNotifications: () -> Void = {}

    // Updates: the newest release, where this build stands, and the installer's progress
    @Published var latestRelease: ReleaseInfo?
    @Published var releaseCheck: SectionState = .ready
    @Published var updateState: UpdateState = .idle
    @Published var checkForUpdate: () -> Void = {}
    @Published var installUpdate: () -> Void = {}
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

    // More apps: the registry's list (the last good read, else the copy in the bundle), its icons by registry path,
    // and the Mac apps found on this Mac (keyed by bundle id)
    @Published var moreAppsRegistry: AppRegistry?
    /// When the list shown was read; nil for the bundled copy, which goes by the registry's own update time.
    @Published var moreAppsReadAt: Date?
    @Published var moreAppIcons: [String: NSImage] = [:]
    @Published var moreAppsInstalled: [String: InstalledCopy] = [:]
    @Published var moreAppsChecking = false
    @Published var moreAppsProblem: String?
    /// True for a press on the refresh button: it reads even when the last read is under an hour old.
    @Published var refreshMoreApps: (_ byPress: Bool) -> Void = { _ in }

    // Settings
    @Published var settingsPane: SettingsPane = .general
    /// Nil in the screenshots: edits then change only this model.
    @Published var configStore: ConfigStore?
    @Published var vpnServices: [(name: String, state: String)] = []
    @Published var physicalInterface: String?
    @Published var historyBytes: Int64?
    @Published var clearHistory: () -> Void = {}
    @Published var lastCleared: Date?
    @Published var clearError: String?
    @Published var clearing = false
    /// Why the login item could not be set. In the model, not the pane: a look change rebuilds the Settings tree.
    @Published var loginProblem: String?

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
