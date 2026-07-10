import SwiftUI

/// Right panel: live-tunable routing parameters. Every change is applied to
/// the running router (debounced) and the current query is re-routed.
struct ParametersPanel: View {
    @ObservedObject var model: PlaygroundModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Parámetros").font(.headline)

                section("Abstención") {
                    slider(
                        "Umbral de confianza",
                        value: $model.minimumConfidence, in: 0...0.95,
                        format: "%.2f",
                        help: "Responde solo si P(correcta) ≥ umbral"
                    )
                    Toggle("Abstenerse si es ambiguo", isOn: $model.abstainOnAmbiguity)
                        .font(.caption)
                    if model.abstainOnAmbiguity {
                        slider(
                            "Margen mínimo",
                            value: $model.minimumMargin, in: 0...0.4,
                            format: "%.2f",
                            help: "Diferencia mínima entre los dos primeros"
                        )
                    }
                }

                section("Tier semántico") {
                    slider(
                        "Suelo de similitud",
                        value: $model.similarityFloor, in: 0.3...0.9,
                        format: "%.2f",
                        help: "Coseno que mapea a señal 0"
                    )
                    slider(
                        "Techo de similitud",
                        value: $model.similarityCeiling, in: 0.5...1.0,
                        format: "%.2f",
                        help: "Coseno que mapea a señal 1"
                    )
                    slider(
                        "Bonus de acuerdo",
                        value: $model.agreementBonus, in: 0...0.5,
                        format: "%.2f",
                        help: "Refuerzo cuando léxico y semántico coinciden"
                    )
                }

                section("Resultados") {
                    slider(
                        "Candidatos mostrados",
                        value: $model.maxCandidates, in: 1...20,
                        format: "%.0f", step: 1
                    )
                }

                section("Contexto") {
                    TextField("hints, separados por comas", text: $model.contextHints)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                    Text("P. ej. \"mp4\" al tener un vídeo seleccionado")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    @ViewBuilder
    private func slider(
        _ label: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String,
        step: Double? = nil,
        help: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
            if let help {
                Text(help).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }
}
