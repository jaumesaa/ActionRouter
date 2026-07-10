import ActionRouter
import AppKit
import SwiftUI

/// Left panel: routing backend selection plus the dynamic action set.
struct ActionsSidebar: View {
    @ObservedObject var model: PlaygroundModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Backend").font(.headline)
            Picker("", selection: $model.providerChoice) {
                ForEach(PlaygroundModel.ProviderChoice.allCases) { choice in
                    Text(choice.rawValue)
                        .tag(choice)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.isPreparingProvider)
            if !model.e5Available {
                Text("Modelo e5 no encontrado. Genera tools/convert/build con convert_e5.py y ejecuta desde la raíz del repo.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Divider()

            HStack {
                Text("Acciones").font(.headline)
                Spacer()
                Button("Cargar JSON…", action: openActionsFile)
                    .controlSize(.small)
            }
            Text(model.actionsSourceName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let error = model.loadError {
                Text(error).font(.caption2).foregroundStyle(.red)
            }

            List {
                ForEach(model.actions) { action in
                    Toggle(isOn: binding(for: action.id)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(action.name).font(.system(size: 12))
                            Text(action.id)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.plain)

            HStack {
                Button("Todas") { model.enabledIDs = Set(model.actions.map(\.id)) }
                Button("Ninguna") { model.enabledIDs = [] }
                Spacer()
                Button("Reset") { model.resetActions() }
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { model.enabledIDs.contains(id) },
            set: { enabled in
                if enabled { model.enabledIDs.insert(id) } else { model.enabledIDs.remove(id) }
            }
        )
    }

    private func openActionsFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.loadActions(from: url)
        }
    }
}
