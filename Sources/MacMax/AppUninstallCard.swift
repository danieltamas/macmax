import MacMaxCore
import SwiftUI

/// Pick an app, see what it left in the Library with sizes, and move the lot to the Trash after one confirmation.
/// Everything lands in the Trash, where it can be put back. System-wide files (in /Library) are never touched.
struct AppUninstallCard: View {
    let model: PanelModel
    @State private var search = ""
    @State private var showAll = false
    @State private var selected: String?
    @State private var excluded: Set<String> = []
    @State private var added: Set<String> = []
    @State private var confirming = false
    @State private var sort = Sort.name
    @Environment(\.panelVisible) private var panelVisible
    private static let staleSeconds: TimeInterval = 60
    enum Sort: String, CaseIterable { case name = "Name", size = "Size", opened = "Last opened" }
    private static let preview = 6
    private static let sizeWidth: CGFloat = 70

    init(model: PanelModel, selected: String? = nil) {
        self.model = model
        _selected = State(initialValue: selected)
    }

    var body: some View {
        SettingsCard(title: "Uninstall apps", detail: "Move an app and the files it left behind to the Trash. You can put everything back from the Trash.") {
            VStack(alignment: .leading, spacing: 8) {
                if case let .loading(text) = model.installedAppsState { OperationProgress(text: text) }
                if model.uninstallStopping {
                    OperationProgress(text: "Stopping what \(model.uninstalledName ?? "the app") still runs in the background...")
                } else if let progress = model.uninstallProgress {
                    OperationProgress(text: "Moving \(min(progress.done + 1, progress.total)) of \(progress.total) to the Trash", fraction: Double(progress.done) / Double(max(progress.total, 1)))
                } else if !model.uninstallResults.isEmpty, !isListed(model.uninstallResults.first?.path) { results }
                if let apps = model.installedApps { list(apps) }
                if !model.installedAppsState.isLoading {
                    PillButton(title: model.installedApps == nil ? "Look at my apps" : "Read again", symbol: "magnifyingglass", prominent: false) { model.scanInstalledApps() }
                }
            }
        }
        .onAppear { if model.installedApps == nil { model.scanInstalledApps() } }
        // Apps come and go outside MacMax: a list older than a minute is read again when the panel opens.
        .onChange(of: panelVisible) { _, visible in
            if visible, model.installedApps != nil, Date().timeIntervalSince(model.installedAppsAt ?? .distantPast) > Self.staleSeconds { model.scanInstalledApps() }
        }
    }

    @ViewBuilder private func list(_ apps: [InstalledApp]) -> some View {
        if model.installedAppsUnreadable > 0 {
            Text("\(model.installedAppsUnreadable) item\(model.installedAppsUnreadable == 1 ? "" : "s") in the Applications folders (links, or apps without a readable Info.plist) not listed.")
                .font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
        GlassField(placeholder: "Search apps", text: $search)
        sortChips
        let matches = sorted(apps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) })
        let shown = showAll || !search.isEmpty ? matches : Array(matches.prefix(Self.preview))
        if matches.isEmpty { Text("No app matches.").font(.meta).foregroundStyle(Theme.textSecondary) }
        ForEach(shown) { app in
            row(app)
            if selected == app.path { detail(app) }
        }
        if search.isEmpty, matches.count > Self.preview {
            Button(showAll ? "Show fewer" : "Show all \(matches.count)") { showAll.toggle() }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.teal).pointingHandCursor()
        }
    }

    private var sortChips: some View {
        HStack(spacing: 6) {
            Text("Sort by").font(.meta).foregroundStyle(Theme.textTertiary)
            ForEach(Sort.allCases, id: \.self) { option in
                Button(option.rawValue) { sort = option }
                    .buttonStyle(.plain).font(.system(size: 11, weight: sort == option ? .semibold : .regular))
                    .foregroundStyle(sort == option ? Theme.teal : Theme.textSecondary).pointingHandCursor()
            }
        }
    }

    private func lastOpened(_ app: InstalledApp) -> Date? { model.appLastOpened[app.path]?.value }

    /// Oldest first for "Last opened" (the ones to consider removing), biggest first for "Size"; unknown goes last.
    private func sorted(_ apps: [InstalledApp]) -> [InstalledApp] {
        switch sort {
        case .name: return apps
        case .size: return apps.sorted { ($0.bytes ?? -1) > ($1.bytes ?? -1) }
        case .opened: return apps.sorted { (lastOpened($0) ?? .distantFuture) < (lastOpened($1) ?? .distantFuture) }
        }
    }

    /// RelativeTime redraws once a minute and follows the README's fixed clock in renders.
    @ViewBuilder private func subtitle(_ app: InstalledApp) -> some View {
        let version = app.version.map { "Version \(Redaction.sanitizeText($0))" }
        let prefix = version.map { $0 + " - " } ?? ""
        switch model.appLastOpened[app.path] {
        case let .ok(date, _, _): RelativeTime(date: date) { "\(prefix)opened \($0.split(separator: ",").first.map(String.init) ?? $0) ago" }
        case .unavailable, .failed: Text(prefix + "no record of being opened")
        case nil: Text(version ?? "")
        }
    }

    private func row(_ app: InstalledApp) -> some View {
        Button { toggle(app) } label: {
            HStack(spacing: 6) {
                Image(systemName: selected == app.path ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary).frame(width: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Redaction.sanitizeText(app.name)).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    subtitle(app).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    if let reason = Self.unavailable(app) { Text("Not available: \(reason)").font(.system(size: 11)).foregroundStyle(Theme.warn).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 4)
                Text(app.bytes.map { CompactFormat.bytes(UInt64(max(0, $0))) } ?? (model.measuringApps.contains(app.path) ? "Measuring..." : "unknown")).font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(Theme.textSecondary).frame(width: Self.sizeWidth, alignment: .trailing)
            }.contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
    }

    @ViewBuilder private func detail(_ app: InstalledApp) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = Self.unavailable(app) {
                Text("MacMax will not uninstall \(app.name): \(reason).").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                ChipButton(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }.fixedSize()
            } else if model.uninstallResults.first?.path == app.path, !model.uninstallResults.isEmpty {
                results
            }
            if Self.unavailable(app) != nil {
                EmptyView()
            } else if model.leftoversLoading.contains(app.path) || model.appLeftovers[app.path] == nil {
                OperationProgress(text: "Looking for what \(app.name) left behind...")
            } else {
                let leftovers = model.appLeftovers[app.path] ?? []
                let chosen = leftovers.filter { chosenLeftover($0) }
                Text(leftovers.isEmpty ? "It left nothing in your Library." : "Left behind in your Library:").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                ForEach(leftovers) { leftoverRow($0) }
                Text("Files in /Library (for all users) are not touched: they need an administrator.").font(.meta).foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions(app, chosen: chosen)
            }
        }
        .padding(.leading, 10).padding(.vertical, 4)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 2) }
    }

    private func leftoverRow(_ leftover: Leftover) -> some View {
        Button {
            if leftover.match == .bundleID { if !excluded.insert(leftover.path).inserted { excluded.remove(leftover.path) } }
            else if !added.insert(leftover.path).inserted { added.remove(leftover.path) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: chosenLeftover(leftover) ? "checkmark.square.fill" : "square").font(.system(size: 13))
                    .foregroundStyle(chosenLeftover(leftover) ? Theme.teal : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Self.kindName(leftover.kind)).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                    Text(Self.inHome(leftover.path)).font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.middle)
                    if leftover.match == .name { Text("Matched by the app's name only: check it is really this app's").font(.meta).foregroundStyle(Theme.warn) }
                }
                Spacer(minLength: 4)
                Text(leftover.bytes.map { CompactFormat.bytes(UInt64(max(0, $0))) } ?? (model.measuringLeftovers.contains("\(selected ?? "")\n\(leftover.path)") ? "Measuring..." : "unknown")).font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Theme.textSecondary).frame(width: Self.sizeWidth, alignment: .trailing)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).pointingHandCursor()
    }

    @ViewBuilder private func actions(_ app: InstalledApp, chosen: [Leftover]) -> some View {
        let bytes = chosen.reduce(app.bytes ?? 0) { saturatingSum($0, $1.bytes ?? 0) }
        // A size that is still being measured, or could not be, is left out of the total rather than counted as zero.
        let complete = app.bytes != nil && chosen.allSatisfy { $0.bytes != nil }
        if model.uninstalling != nil {
            EmptyView()
        } else if confirming {
            Text("Move \(app.name) and \(chosen.count) leftover\(chosen.count == 1 ? "" : "s")\(complete ? " (\(CompactFormat.bytes(UInt64(max(0, bytes)))))" : "") to the Trash? Quit the app first if it is open.")
                .font(.meta).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                PillButton(title: "Yes, move to Trash", symbol: "trash") { confirming = false; model.uninstallApp(app, chosen) }
                ChipButton(title: "Cancel") { confirming = false }.fixedSize()
            }
        } else {
            PillButton(title: "Move to Trash", symbol: "trash", prominent: false) { confirming = true }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 3) {
            let moved = model.uninstallResults.filter { $0.outcome == .done }.count
            let appMoved = model.uninstallResults.first?.outcome == .done
            Text(appMoved ? "\(model.uninstalledName ?? "The app"): moved \(moved) of \(model.uninstallResults.count) to the Trash."
                 : "\(model.uninstalledName ?? "The app") was not moved. Nothing else was moved either.")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(moved == model.uninstallResults.count ? Theme.success : Theme.warn)
            // When the app stayed, its leftovers stayed for the same reason: one line, not one per file.
            ForEach(Array(model.uninstallResults.prefix(appMoved ? model.uninstallResults.count : 1).enumerated()), id: \.offset) { _, result in
                switch result.outcome {
                case .done: EmptyView()
                case let .refused(reason), let .failed(reason):
                    Text(Redaction.sanitizeText("\((result.path as NSString).lastPathComponent): \(reason)")).font(.meta).foregroundStyle(Theme.warn)
                        .lineLimit(5).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func toggle(_ app: InstalledApp) {
        confirming = false
        model.uninstallResults = []
        if selected == app.path { selected = nil; return }
        // Removed outside MacMax since the list was read: say so by reading the list again.
        guard FileManager.default.fileExists(atPath: app.path) else { model.scanInstalledApps(); return }
        selected = app.path
        excluded = []
        added = []
        if Self.unavailable(app) == nil { model.loadLeftovers(app) }
    }

    private func isListed(_ path: String?) -> Bool { model.installedApps?.contains { $0.path == path } == true }

    private static func unavailable(_ app: InstalledApp) -> String? { AppUninstallPolicy.unavailable(for: app, home: NSHomeDirectory()) }

    private func chosenLeftover(_ leftover: Leftover) -> Bool {
        leftover.match == .bundleID ? !excluded.contains(leftover.path) : added.contains(leftover.path)
    }

    /// From `Library/` on: the part that tells one leftover from another.
    private static func inHome(_ path: String) -> String {
        Redaction.sanitizeText(path.range(of: "/Library/").map { String(path[path.index(after: $0.lowerBound)...]) } ?? path)
    }

    private static func kindName(_ kind: LeftoverKind) -> String {
        switch kind {
        case .applicationSupport: "Support files"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .container: "Sandbox container"
        case .logs: "Logs"
        case .savedState: "Saved window state"
        case .httpStorage: "Web storage"
        case .webKit: "Web data"
        case .cookies: "Cookies"
        case .launchAgent: "Launch agent (starts at login)"
        }
    }
}

private func saturatingSum(_ left: Int64, _ right: Int64) -> Int64 {
    let (sum, overflow) = left.addingReportingOverflow(right)
    return overflow ? Int64.max : sum
}
