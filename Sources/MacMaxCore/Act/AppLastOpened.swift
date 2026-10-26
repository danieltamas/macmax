import CoreServices
import Foundation

/// When an app was last opened, from Spotlight's record. "No record" is not "never opened": Spotlight may be off or
/// not have indexed the app, so it is reported as unavailable and shown as such.
public enum AppLastOpened {
    public static func read(path: String, at: Date = .now) -> Reading<Date> {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else {
            return .unavailable(reason: "Spotlight has no record of this app")
        }
        guard let date = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date else {
            return .unavailable(reason: "Spotlight has no record of this app being opened")
        }
        return .ok(date, source: "Spotlight", at: at)
    }
}
