import SwiftUI

struct NoiseControlCard: View {
    @Environment(HeadphoneStore.self) private var store
    @State private var isExpanded: Bool
    @State private var reservesAmbientSpace = false
    @State private var showsAmbientControls = false

    init() {
        _isExpanded = State(initialValue: UserDefaults.standard.object(forKey: "xmgo.module.sound.open") as? Bool ?? true)
    }

    var body: some View {
        @Bindable var store = store
        CollapsibleGlassCard(title: "Sound Control", systemImage: "waveform.badge.mic", expanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 18) {
                NoiseModePicker(selection: Binding(
                    get: { store.headphone.noiseControl },
                    set: { store.setNoiseControl($0) }
                ))

                if reservesAmbientSpace {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Ambient level")
                            Spacer()
                            Text("\(store.headphone.ambientLevel)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 10) {
                            Image(systemName: "waveform.low")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Less ambient sound")
                            Slider(value: Binding(
                                get: { Double(store.headphone.ambientLevel) },
                                set: { store.setAmbientLevel(Int($0.rounded())) }
                            ), in: 1...20, step: 1)
                            Image(systemName: "waveform")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("More ambient sound")
                        }
                        Toggle("Focus on Voice", isOn: Binding(
                            get: { store.headphone.focusOnVoice }, set: { store.setFocusOnVoice($0) }
                        ))
                    }
                    .opacity(showsAmbientControls ? 1 : 0)
                    .allowsHitTesting(showsAmbientControls)
                }
            }
            .disabled(!store.canControl)
        }
        .onAppear { setAmbientVisibility(for: store.headphone.noiseControl, immediately: true) }
        .onChange(of: store.headphone.noiseControl) { _, mode in setAmbientVisibility(for: mode, immediately: false) }
    }

    private func setAmbientVisibility(for mode: NoiseControlMode, immediately: Bool) {
        if mode == .ambient {
            reservesAmbientSpace = true
            if immediately {
                withAnimation(.easeIn(duration: 0.14)) { showsAmbientControls = true }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
                    withAnimation(.easeIn(duration: 0.14)) { showsAmbientControls = true }
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.12)) { showsAmbientControls = false }
            if immediately {
                withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.88)) { reservesAmbientSpace = false }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                    withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.88)) { reservesAmbientSpace = false }
                }
            }
        }
    }
}

private struct NoiseModePicker: View {
    @Binding var selection: NoiseControlMode
    @Namespace private var selectionAnimation

    var body: some View {
        HStack(spacing: 4) {
            ForEach(NoiseControlMode.allCases) { mode in
                Button {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.82)) { selection = mode }
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: mode.symbol).font(.headline)
                        Text(mode.rawValue).font(.caption2.weight(.semibold)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 58)
                    .foregroundStyle(selection == mode ? .primary : .secondary)
                    .background {
                        if selection == mode {
                            Capsule()
                                .fill(.tint.opacity(0.30))
                                .matchedGeometryEffect(id: "selectedNoiseMode", in: selectionAnimation)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Audio mode")
    }
}
