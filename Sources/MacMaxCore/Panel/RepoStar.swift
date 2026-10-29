import Foundation

/// The "Star on GitHub" offer in the panel footer. It asks GitHub once whether the user's `gh` account has starred
/// MacMax, remembers a yes in `config.json` (`starred_repo`) and never asks again. Starring is the user's click and
/// nothing else: the call goes through their own logged-in `gh`, and nothing is sent anywhere else.
public struct RepoStar: Sendable {
    public enum Standing: Equatable, Sendable { case starred, notStarred, unknown }

    /// Runs `gh` with arguments and returns its exit status and standard output.
    public typealias GH = @Sendable ([String]) async -> (status: Int32, output: String)

    public static let repo = "danieltamas/macmax"

    private let store: ConfigStore
    private let gh: GH

    public init(home: MacMaxHome, gh: @escaping GH = RepoStar.realGH) {
        store = ConfigStore(home: home)
        self.gh = gh
    }

    /// Whether the footer may offer the star, read from disk only. A config that does not parse is unknown: no offer.
    public func shouldOffer() -> Bool {
        guard case let .ok(config) = store.load() else { return false }
        return config.starredRepo != true
    }

    /// Asks GitHub once; a yes is remembered. No `gh`, no login or no answer is `unknown`: nothing is offered then.
    public func refresh() async -> Standing {
        switch store.load() {
        case .malformed: return .unknown
        case let .ok(config) where config.starredRepo == true: return .starred
        case .ok: break
        }
        let answer = await gh(["api", "-i", "user/starred/\(Self.repo)"])
        switch Self.httpStatus(answer.output) {
        case 204:
            await remember()
            return .starred
        case 404: return .notStarred
        default: return .unknown
        }
    }

    /// Stars the repository for the user's `gh` account. True when GitHub said so (204), and then it is remembered;
    /// a save that fails only means the next launch asks GitHub again.
    public func star() async -> Bool {
        let answer = await gh(["api", "-i", "-X", "PUT", "user/starred/\(Self.repo)"])
        guard Self.httpStatus(answer.output) == 204 else { return false }
        await remember()
        return true
    }

    /// On the main actor, where Settings saves too: two read-modify-writes of `config.json` never interleave.
    private func remember() async {
        await MainActor.run { _ = try? store.update { $0.starredRepo = true } }
    }

    /// The status code on `gh api -i`'s first line ("HTTP/2.0 204 No Content"); nil when there is none.
    static func httpStatus(_ output: String) -> Int? {
        guard let line = output.split(whereSeparator: \.isNewline).first, line.hasPrefix("HTTP/") else { return nil }
        return line.split(separator: " ").dropFirst().first.flatMap { Int($0) }
    }

    /// `GH_HOST` is pinned: an inherited one would send the question to a GitHub Enterprise server instead.
    public static let realGH: GH = { arguments in
        guard let gh = Executables.resolve("gh") else { return (127, "") }
        let environment = ["PATH": Executables.searchPath(for: gh), "GH_HOST": "github.com"]
        guard let output = try? await ProcessRunner().run(gh, arguments, environment: environment, timeout: .seconds(30))
        else { return (1, "") }
        return (output.status, String(decoding: output.stdout, as: UTF8.self))
    }
}
