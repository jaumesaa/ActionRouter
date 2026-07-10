import ActionRouter
import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model = PlaygroundModel()
    @FocusState private var queryFocused: Bool

    var body: some View {
        HSplitView {
            ActionsSidebar(model: model)
                .frame(minWidth: 230, idealWidth: 250, maxWidth: 320)
            resultsColumn
                .frame(minWidth: 440, maxWidth: .infinity)
            ParametersPanel(model: model)
                .frame(minWidth: 230, idealWidth: 250, maxWidth: 300)
        }
        .onAppear { queryFocused = true }
    }

    private var resultsColumn: some View {
        VStack(spacing: 0) {
            queryBar
            Divider()
            decisionBanner
            ScrollView {
                LazyVStack(spacing: 8) {
                    if let result = model.result {
                        ForEach(Array(result.candidates.enumerated()), id: \.element.action.id) { rank, candidate in
                            CandidateRow(
                                rank: rank + 1,
                                candidate: candidate,
                                isWinner: rank == 0 && result.match != nil,
                                threshold: model.minimumConfidence
                            )
                        }
                    }
                }
                .padding(12)
            }
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var queryBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Escribe una petición… p. ej. \"treu el fons de la foto\"", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .focused($queryFocused)
            if model.isPreparingProvider {
                ProgressView().controlSize(.small)
                Text("loading model…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var decisionBanner: some View {
        if let result = model.result, !model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            HStack(spacing: 8) {
                switch result.decision {
                case .matched(let match):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(match.action.name).fontWeight(.semibold)
                    Text(String(format: "P(correcta) = %.0f%%", match.confidence * 100))
                        .foregroundStyle(.secondary)
                case .abstained(let reason):
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                    Text("Abstención").fontWeight(.semibold)
                    Text(describe(reason)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(String(format: "%.1f ms", milliseconds(result.duration)))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(bannerColor(for: result).opacity(0.12))
        }
    }

    private func bannerColor(for result: RoutingResult) -> Color {
        result.match != nil ? .green : .orange
    }

    private func describe(_ reason: AbstentionReason) -> String {
        switch reason {
        case .emptyQuery:
            return "consulta vacía"
        case .noActionsRegistered:
            return "ninguna acción disponible"
        case .insufficientConfidence(let best, let required):
            return String(format: "mejor P %.0f%% < umbral %.0f%%", best * 100, required * 100)
        case .ambiguous(let margin, let required):
            return String(format: "ambigua (margen %.2f < %.2f)", margin, required)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            statusDot
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text("\(model.enabledIDs.count)/\(model.actions.count) acciones activas")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var statusDot: some View {
        Circle().frame(width: 8, height: 8).foregroundStyle(statusColor)
    }

    private var statusColor: Color {
        switch model.semanticStatus {
        case .ready: return .green
        case .disabled: return .gray
        case .notPrepared: return .yellow
        case .unavailable: return .red
        }
    }

    private var statusText: String {
        switch model.semanticStatus {
        case .ready: return "tier semántico activo"
        case .disabled: return "solo léxico"
        case .notPrepared: return "semántico pendiente"
        case .unavailable(let reason): return "semántico no disponible: \(reason)"
        }
    }
}

func milliseconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000
        + Double(duration.components.attoseconds) / 1e15
}
