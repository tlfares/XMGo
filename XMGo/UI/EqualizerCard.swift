import SwiftUI

struct EqualizerCard: View {
    @Environment(HeadphoneStore.self) private var store
    @State private var isExpanded: Bool

    init() {
        _isExpanded = State(initialValue: UserDefaults.standard.object(forKey: "xmgo.module.equalizer.open") as? Bool ?? false)
    }

    var body: some View {
        CollapsibleGlassCard(title: "Equalizer", systemImage: "slider.vertical.3", expanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer()
                    Menu("Presets") {
                        Button("Flat (Default)") { apply([0, 0, 0, 0, 0], bass: 0) }
                        Button("Bass Boost") { apply([3, 2, 0, -1, -1], bass: 7) }
                        Button("Reduced bass") { apply([-4, -3, -1, 0, 1], bass: -6) }
                        Button("Warm") { apply([2, 1, 0, 1, 2], bass: 3) }
                        Button("Vocal") { apply([-2, 1, 4, 2, 0], bass: -2) }
                        Button("Clear") { apply([0, 1, 3, 4, 3], bass: -1) }
                    }
                    .font(.subheadline)
                }

                HStack(alignment: .bottom, spacing: 9) {
                    ForEach(EqualizerSettings.frequencies.indices, id: \.self) { index in
                        EqualizerBand(
                            label: EqualizerSettings.frequencies[index],
                            value: Binding(
                                get: { store.headphone.equalizer.bands[index] },
                                set: { store.updateBand(index, value: $0) }
                            )
                        )
                    }
                }
                .frame(height: 172)

                HStack {
                    Text("Clear Bass")
                    Slider(value: Binding(
                        get: { store.headphone.equalizer.clearBass },
                        set: { store.setClearBass($0) }
                    ), in: -10...10, step: 1)
                    Text(store.headphone.equalizer.clearBass.formatted(.number.precision(.fractionLength(0))))
                        .monospacedDigit()
                        .frame(width: 24)
                }
                .font(.subheadline)
            }
            .disabled(!store.canControl)
        }
    }

    private func apply(_ bands: [Double], bass: Double) {
        let equalizer = EqualizerSettings(bands: bands, clearBass: bass)
        withAnimation(.smooth) {
            store.applyEqualizer(equalizer)
        }
    }
}

private struct EqualizerBand: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 7) {
            Text(value.formatted(.number.precision(.fractionLength(0)).sign(strategy: .always())))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            Slider(value: $value, in: -10...10, step: 1)
                .rotationEffect(.degrees(-90))
                .frame(width: 112, height: 30)
                .frame(width: 42, height: 112)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
