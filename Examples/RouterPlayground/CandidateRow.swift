import ActionRouter
import SwiftUI

/// One ranked candidate: confidence, fused score and per-signal bars.
struct CandidateRow: View {
    let rank: Int
    let candidate: RouteMatch
    let isWinner: Bool
    let threshold: Double

    private static let signalOrder: [(RoutingSignal, String, Color)] = [
        (.exactName, "nombre exacto", .blue),
        (.namePrefix, "prefijo", .blue),
        (.tokenSupport, "tokens", .blue),
        (.phraseSimilarity, "frase (trigramas)", .blue),
        (.bm25, "BM25", .blue),
        (.semanticSimilarity, "semántico", .purple),
        (.contextAffinity, "contexto", .orange),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            bars
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isWinner ? Color.green.opacity(0.08) : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isWinner ? Color.green.opacity(0.4) : Color.gray.opacity(0.15))
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(rank)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(candidate.action.name)
                .fontWeight(isWinner ? .semibold : .regular)
            Text(candidate.action.id)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
            Spacer()
            if let cosine = candidate.signals[.semanticCosine] {
                Text(String(format: "cos %.3f", cosine))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.purple.opacity(0.8))
            }
            Text(String(format: "fused %.3f", candidate.fusedScore))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
            confidenceBadge
        }
    }

    private var confidenceBadge: some View {
        Text(String(format: "%.0f%%", candidate.confidence * 100))
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .foregroundStyle(candidate.confidence >= threshold ? Color.green : Color.secondary)
            .frame(width: 48, alignment: .trailing)
    }

    private var bars: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(Self.signalOrder.filter { candidate.signals[$0.0] != nil }, id: \.0) { signal, label, color in
                GridRow {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    SignalBar(value: candidate.signals[signal] ?? 0, color: color)
                    Text(String(format: "%.2f", candidate.signals[signal] ?? 0))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .frame(width: 32, alignment: .trailing)
                }
            }
        }
    }
}

struct SignalBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.12))
                Capsule()
                    .fill(color.opacity(0.75))
                    .frame(width: max(0, min(1, value)) * proxy.size.width)
                    .animation(.easeOut(duration: 0.15), value: value)
            }
        }
        .frame(height: 6)
    }
}
