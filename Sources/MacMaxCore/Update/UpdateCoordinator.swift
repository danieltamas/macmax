import Darwin
import Foundation

public enum UpdateState: Sendable, Equatable {
    case idle
    case updating(String)
    case failed(String)
}

/// Starts the installer at most once: the in-flight state lives here, not in a view, so a second press, or one from
/// another window, finds an update already running.
public actor UpdateCoordinator {
    private let launch: @Sendable (String) throws -> Void
    private var current = UpdateState.idle

    public init(launch: @escaping @Sendable (String) throws -> Void) { self.launch = launch }

    public var state: UpdateState { current }

    public func start(version: String) -> UpdateState {
        if case .updating = current { return current }
        guard let numbers = SemanticVersion.parse(version), !version.hasPrefix("v"), SemanticVersion.text(numbers) == version else {
            current = .failed("The version to install is not X.Y.Z.")
            return current
        }
        do {
            try launch(version)
            current = .updating(version)
        } catch {
            current = .failed(Redaction.sanitizeText(error.localizedDescription))
        }
        return current
    }

    /// The installer ended while this app was still running, so it did not replace it: a later press may try again.
    public func installerStopped(reason: String) -> UpdateState {
        current = .failed(Redaction.sanitizeText(reason))
        return current
    }
}

public enum UpdateLog {
    public struct Failure: LocalizedError {
        public var errorDescription: String? { reason }
        public let reason: String
        public init(reason: String) { self.reason = reason }
    }

    /// The installer's log: created 0600, never through a symlink, and only ever a regular file.
    public static func open(at url: URL) throws -> Int32 {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw Failure(reason: "the update log could not be opened (\(String(cString: strerror(errno))))") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw Failure(reason: "the update log is not a regular file")
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            Darwin.close(descriptor)
            throw Failure(reason: "the update log's mode could not be set")
        }
        return descriptor
    }

    /// The last non-empty line, for a one-line reason in About.
    public static func lastLine(of text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { Redaction.sanitizeText(String($0)).trimmingCharacters(in: .whitespaces) }
        guard let last = lines.last(where: { !$0.isEmpty }) else { return nil }
        return String(last.prefix(200))
    }
}
