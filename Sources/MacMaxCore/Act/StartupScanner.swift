import Foundation

/// Lists the launchd property lists of this Mac with what launchd says about each. It only reads.
public struct StartupScanner: Sendable {
    static let maxPlistBytes = 1_048_576
    private let runner = ProcessRunner()
    private let home: String

    public init(home: String = NSHomeDirectory()) { self.home = home }

    public static func folders(home: String) -> [(path: String, scope: StartupScope)] {
        [("\(home)/Library/LaunchAgents", .userAgent), ("/Library/LaunchAgents", .globalAgent), ("/Library/LaunchDaemons", .globalDaemon)]
    }

    /// `unreadable` counts the property lists that could not be used (unparseable, too big, a link), so a short list is
    /// not taken for a complete one.
    public static func load(folders: [(path: String, scope: StartupScope)]) -> (items: [StartupItem], unreadable: Int) {
        let fileManager = FileManager.default
        var items: [StartupItem] = []
        var unreadable = 0
        for folder in folders {
            let names: [String]
            do {
                names = try fileManager.contentsOfDirectory(atPath: folder.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch {
                // A folder that exists and cannot be listed is a gap in the answer, not an empty folder.
                unreadable += 1
                continue
            }
            for name in names.sorted() where name.hasSuffix(".plist") {
                let path = folder.path + "/" + name
                guard let data = readPlist(at: path), case let .ok(item, _, _) = StartupParser.parse(data, path: path, scope: folder.scope)
                else { unreadable += 1; continue }
                items.append(item)
            }
        }
        return (items, unreadable)
    }

    /// The bytes of a regular file of at most 1 MB, opened without following a link and checked on the descriptor it is
    /// read from, so a file swapped in after listing is not read.
    static func readPlist(at path: String) -> Data? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= maxPlistBytes else { return nil }
        return try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: false).read(upToCount: maxPlistBytes + 1)
    }

    /// The items with their running and turned-off state. A launchctl answer that cannot be read fails the scan:
    /// "nothing is running" is never assumed.
    public func scan() async -> Reading<(items: [StartupItem], unreadable: Int)> {
        let loaded = Self.load(folders: Self.folders(home: home))
        do {
            let list = try await runner.run("/bin/launchctl", ["list"], timeout: .seconds(10))
            let off = try await runner.run("/bin/launchctl", ["print-disabled", "gui/\(getuid())"], timeout: .seconds(10))
            let listText = String(decoding: list.stdout, as: UTF8.self), offText = String(decoding: off.stdout, as: UTF8.self)
            // Both answers must have the shape launchctl prints: an empty or cut-short one would read as "nothing runs".
            guard list.status == 0, off.status == 0, listText.hasPrefix("PID\tStatus\tLabel"), offText.contains("disabled services = {"), offText.contains("}")
            else { return .failed(reason: "launchctl did not answer in the expected form.") }
            let items = StartupAnalysis.items(loaded.items, running: LaunchctlList.running(listText), disabled: LaunchctlList.disabled(offText))
            return .ok((items, loaded.unreadable), source: "launchctl", at: Date())
        } catch {
            return .failed(reason: "launchctl could not be run.")
        }
    }

    /// Runs the commands for one item in order and stops at the first that fails. Returns how many succeeded, so a
    /// half-done change can be told from none.
    public func run(_ commands: [[String]]) async -> Int {
        var succeeded = 0
        for command in commands {
            guard let executable = command.first,
                  let output = try? await runner.run(executable, Array(command.dropFirst()), timeout: .seconds(10)),
                  output.status == 0 else { break }
            succeeded += 1
        }
        return succeeded
    }
}
