import Foundation
import MacMaxCore

/// Old downloads: the scan runs only on a press (macOS may ask to let MacMax into Downloads), and the move after one
/// confirmation in the card. What may move is decided in MacMaxCore (OldDownloads, OldDownloadsMover).
extension ActionController {
    func scanOldDownloads() {
        guard !model.oldDownloadsState.isLoading, !model.oldDownloadsMoving else { return }
        guard let protected = protectedPaths() else {
            model.oldDownloadsState = .failed(collector: "The settings file", reason: "It could not be read, so MacMax cannot tell what is protected.")
            return
        }
        let days = model.oldDownloadsDays
        model.oldDownloadsState = .loading("Looking through Downloads...")
        Task {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let reading = await Task.detached(priority: .utility) { OldDownloads.scan(home: home, userProtected: protected, olderThanDays: days, now: Date()) }.value
            // The age was changed while this ran: the list is for an age that is no longer chosen.
            guard days == model.oldDownloadsDays else {
                model.oldDownloadsState = .ready
                return
            }
            switch reading {
            case let .ok(items, _, _):
                model.oldDownloads = items
                model.oldDownloadsState = .ready
            case let .unavailable(reason):
                model.oldDownloads = nil
                model.oldDownloadsState = .failed(collector: "Downloads", reason: reason)
            case let .failed(reason):
                model.oldDownloads = nil
                model.oldDownloadsState = .failed(collector: "Downloads", reason: reason)
            }
        }
    }

    func moveOldDownloads(_ items: [OldDownload]) {
        guard !model.oldDownloadsMoving, !items.isEmpty else { return }
        guard let protected = protectedPaths() else {
            model.oldDownloadsState = .failed(collector: "The settings file", reason: "It could not be read, so MacMax cannot tell what is protected and will not clean.")
            return
        }
        let days = model.oldDownloadsDays
        model.oldDownloadsMoving = true
        model.oldDownloadsProgress = (0, items.count, nil)
        model.oldDownloadsResults = []
        model.cleanupLogProblem = nil
        Task {
            let results = await Task.detached(priority: .utility) { [model] in
                OldDownloadsMover(home: FileManager.default.homeDirectoryForCurrentUser, userProtected: protected, trasher: FileManagerTrasher())
                    .move(items, olderThanDays: days) { done, total, next in
                        // A callback that lands after the move ended must not bring the bar back.
                        Task { @MainActor in if model.oldDownloadsMoving { model.oldDownloadsProgress = (done, total, next) } }
                    }
            }.value
            for (item, result) in zip(items, results) {
                switch result.outcome {
                case .done: record(kind: "cleanup", target: result.path, result: "trashed", detail: "old_downloads, \(CompactFormat.bytes(UInt64(max(item.bytes, 0))))", key: Self.cleanupKey)
                case let .refused(reason): record(kind: "cleanup", target: result.path, result: "skipped", detail: reason, key: Self.cleanupKey)
                case let .failed(reason): record(kind: "cleanup", target: result.path, result: "failed", detail: reason, key: Self.cleanupKey)
                }
            }
            model.oldDownloadsResults = results
            model.oldDownloadsMoving = false
            model.oldDownloadsProgress = nil
            scanOldDownloads()
            try? await Task.sleep(for: .milliseconds(300))
            model.loadLastCleanups()
        }
    }
}
