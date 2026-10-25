import Foundation

public enum ReportCounter {
    /// Whether `path` exists: a missing path is `false`, but a lookup that failed for another reason (permissions,
    /// an unreadable parent) throws, because "cannot tell" must not read as "absent".
    public static func exists(_ path: String) throws -> Bool {
        do { _ = try FileManager.default.attributesOfItem(atPath: path); return true } catch {
            let code = (error as NSError).code
            if code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError { return false }
            throw error
        }
    }

    /// Regular files directly inside `directories` whose name satisfies `matching` and that were modified less
    /// than `days` days before `now`. A directory that does not exist counts zero; one that cannot be read makes
    /// the whole reading `failed`, because a partial count would read as healthy.
    public static func count(in directories: [URL], matching: (String) -> Bool, modifiedWithinDays days: Int,
                             now: Date, at: Date = Date()) -> Reading<Int> {
        let manager = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var total = 0
        for directory in directories {
            do { guard try exists(directory.path) else { continue } } catch {
                return .failed(reason: "cannot look up \(directory.lastPathComponent)")
            }
            let names: [String]
            do { names = try manager.contentsOfDirectory(atPath: directory.path) } catch {
                return .failed(reason: "cannot read \(directory.lastPathComponent)")
            }
            for name in names where matching(name) {
                // lstat semantics: a symlink is not a regular file and is never followed.
                let attributes: [FileAttributeKey: Any]
                do { attributes = try manager.attributesOfItem(atPath: directory.appendingPathComponent(name).path) } catch {
                    // A report deleted while the directory was being read is gone, not unreadable.
                    if (error as NSError).code == NSFileReadNoSuchFileError { continue }
                    return .failed(reason: "cannot read a report in \(directory.lastPathComponent)")
                }
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let modified = attributes[.modificationDate] as? Date,
                      modified > cutoff else { continue }
                total += 1
            }
        }
        return .ok(total, source: "report directories", at: at)
    }
}
