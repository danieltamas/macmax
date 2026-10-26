import Foundation

public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String)
}

/// Runs a command with `ProcessRunner` and a 30 second limit; a command that did not finish is a failure.
public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        do {
            let result = try await ProcessRunner().run(executable, arguments, timeout: .seconds(30))
            return (result.status, String(decoding: result.stdout, as: UTF8.self))
        } catch {
            return (-1, "the command did not finish in time")
        }
    }
}

public struct DockerActions: Sendable {
    private let runner: CommandRunning
    private let docker: String

    public init(runner: CommandRunning, docker: String) {
        self.runner = runner
        self.docker = docker
    }

    /// `docker stop <id>` after re-reading that the container is running. The id is a hex string, so it can never
    /// be read as an option.
    public func stop(containerID: String) async -> ActionOutcome {
        guard containerID.range(of: "^[0-9a-f]{12,64}$", options: .regularExpression) != nil else {
            return .refused("not a container id")
        }
        let running = await runner.run(docker, ["ps", "--no-trunc", "--format", "{{.ID}}"])
        guard running.status == 0 else { return .failed("Docker did not list the running containers") }
        let ids = running.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let prefix = String(containerID.prefix(12))
        guard ids.contains(where: { $0 == containerID || (containerID.count == 12 && $0.hasPrefix(prefix)) }) else {
            return .refused("not running")
        }
        let stopped = await runner.run(docker, ["stop", containerID])
        return stopped.status == 0 ? .done : .failed("docker stop failed (exit \(stopped.status))")
    }
}
