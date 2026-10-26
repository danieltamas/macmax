import MacMaxCore

/// Where one press has got to. The row shows it at once, so a press never looks like nothing happened.
enum ActionState: Equatable {
    case working(String)
    /// The polite request went out and the target is still there: a second press may force it.
    case asked(String)
    case done(String)
    case refused(String)
    case failed(String)

    var text: String {
        switch self {
        case let .working(text), let .asked(text), let .done(text), let .refused(text), let .failed(text): text
        }
    }

    /// The same state with a note on the end, for an action that happened but could not be logged.
    func noted(_ note: String) -> ActionState {
        switch self {
        case let .working(text): .working(text + note)
        case let .asked(text): .asked(text + note)
        case let .done(text): .done(text + note)
        case let .refused(text): .refused(text + note)
        case let .failed(text): .failed(text + note)
        }
    }

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

struct ContainerLine: Equatable, Identifiable {
    let id: String
    let name: String
}

/// What a press in the app can do. Only the app creates these; the CLI and the MCP server have no way to.
enum PanelAction {
    case endProcess(ProcessLine, force: Bool)
    case endSession(ProcessLine, force: Bool)
    case quit(AppRow, force: Bool)
    case stopContainer(ContainerLine)

    var key: String {
        switch self {
        // Start time too: a reused pid is another process and starts with a clean slate.
        case let .endProcess(line, _): "end-\(line.pid)-\(line.startUs ?? 0)"
        case let .endSession(line, _): "session-\(line.pid)-\(line.startUs ?? 0)"
        case let .quit(row, _): "quit-\(row.id)-\(row.pids.min() ?? 0)"
        case let .stopContainer(container): "container-\(container.id)"
        }
    }
}
