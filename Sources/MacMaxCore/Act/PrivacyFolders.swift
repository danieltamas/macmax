import Foundation

/// The places under home where macOS asks the person before an app may read, one prompt per place, unless the app has
/// Full Disk Access. MacMax lists them in its own prompt and, without access, walks around them.
public enum PrivacyFolders {
    /// Paths relative to the home folder.
    public static let relative: [String] = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
        "Library/Mail", "Library/Messages", "Library/Safari", "Library/Calendars", "Library/Containers",
        "Library/Group Containers", "Library/Mobile Documents", "Library/Cookies", "Library/HomeKit",
        "Library/Suggestions", "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Application Support/CallHistoryTransactions",
    ]

    /// What the prompt shows: the same places in the words a person uses.
    public static let names: [String] = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "iCloud Drive", "Mail and Messages",
        "Safari data", "Calendars and Contacts", "Other apps' data (Containers)",
    ]

    /// The folders to walk instead of `home` as a whole: every child that is not a protected place, descending only
    /// through folders that hold one. Each comes with the du depth that keeps the total at `depth` levels below home.
    public static func walkable(home: String, depth: Int, fileManager: FileManager = .default) -> [(path: String, depth: Int)] {
        var result: [(String, Int)] = []
        func visit(_ directory: String, _ prefix: String, _ level: Int) {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory) else { return }
            for name in names.sorted() {
                let relativePath = prefix.isEmpty ? name : prefix + "/" + name
                if relative.contains(relativePath) { continue }
                let path = directory + "/" + name
                if relative.contains(where: { $0.hasPrefix(relativePath + "/") }) { visit(path, relativePath, level + 1) }
                else if level < depth { result.append((path, depth - level)) }
            }
        }
        visit(home, "", 1)
        return result
    }
}
