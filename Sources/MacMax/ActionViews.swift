import MacMaxCore
import SwiftUI

/// One press and where it got to: the button, then the answer. After a polite request that did not end it, the same
/// place offers the forceful one. Nothing is signalled until the press.
struct ActionControl: View {
    let model: PanelModel
    let action: PanelAction
    let forced: PanelAction
    let title: String
    let forceTitle: String

    private var state: ActionState? { model.actionStates[action.key] }

    var body: some View {
        HStack(spacing: 8) {
            switch state {
            case .asked:
                Button(forceTitle) { model.perform(forced) }.buttonStyle(PressStyle()).foregroundStyle(Theme.crit)
            case .working, .done:
                EmptyView()
            default:
                Button(title) { model.perform(action) }.buttonStyle(PressStyle()).foregroundStyle(Theme.teal)
            }
            if let state {
                Text(state.text).foregroundStyle(color(state)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.meta)
    }

    private func color(_ state: ActionState) -> Color {
        switch state {
        case .working, .asked, .done: Theme.textSecondary
        case .refused: Theme.warn
        case .failed: Theme.crit
        }
    }
}

/// The running containers of Docker, read when asked, each with a Stop that re-checks it is still running.
struct ContainersList: View {
    let model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Eyebrow(text: "Containers")
                Spacer(minLength: 6)
                Button("Refresh") { model.loadContainers() }.buttonStyle(PressStyle()).font(.meta).foregroundStyle(Theme.teal)
            }
            switch model.containersState {
            case let .loading(text): Text(text).font(.meta).foregroundStyle(Theme.textTertiary)
            case let .failed(_, reason): Text(reason).font(.meta).foregroundStyle(Theme.warn)
            case .ready:
                if model.containers.isEmpty {
                    Text("Press Refresh to list the running containers.").font(.meta).foregroundStyle(Theme.textTertiary)
                }
                ForEach(model.containers) { container in
                    HStack(spacing: 8) {
                        Text(container.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        ActionControl(model: model, action: .stopContainer(container), forced: .stopContainer(container),
                                      title: "Stop", forceTitle: "Stop")
                    }
                }
            }
        }
    }
}
