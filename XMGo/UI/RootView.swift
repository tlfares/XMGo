import SwiftUI

struct RootView: View {
    @Environment(HeadphoneStore.self) private var store
    @State private var selectedTab: XMGoTab = .headphones
    @AppStorage("xmgo.tint.choice") private var tintChoice = "black"
    @AppStorage("xmgo.tint.custom") private var customTint = "#DCAA61"

    private var tint: Color { Color(xmHex: XMColorTheme.hex(choice: tintChoice, custom: customTint)) }

    var body: some View {
        @Bindable var store = store
        TabView(selection: $selectedTab) {
            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    dashboard
                }
                .navigationTitle("XMGo")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { store.presentScanner() } label: { Image(systemName: "headphones") }
                            .accessibilityLabel("Change headset")
                    }
                }
            }
            .tabItem { Label("Headset", systemImage: "headphones") }
            .tag(XMGoTab.headphones)

            NavigationStack {
                ZStack {
                    Color.black.ignoresSafeArea()
                    XMGoSettingsView()
                }
                .navigationTitle("Settings")
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(XMGoTab.settings)
        }
        .tint(tint)
        .sheet(isPresented: $store.showsDevicePicker) { DevicePickerView() }
        .task {
            if tintChoice == "headset" { tintChoice = "black" }
            store.start()
        }
    }

    private var dashboard: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                DeviceHeroView()
                if let message = store.controlMessage {
                    ControlAvailabilityNotice(
                        message: message,
                        retry: store.retryControlNow,
                        canRepair: store.needsRepair,
                        repair: store.repairControlLink
                    )
                }
                NoiseControlCard()
                EqualizerCard()
                QuickSettingsCard()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }
}

private enum XMGoTab: Hashable { case headphones, settings }

private struct ControlAvailabilityNotice: View {
    let message: String
    let retry: () -> Void
    var canRepair: Bool = false
    var repair: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(action: retry) { Label("Connect", systemImage: "antenna.radiowaves.left.and.right") }
                    .buttonStyle(.borderedProminent)
                if canRepair, let repair {
                    Button(action: repair) { Label("Repair link", systemImage: "arrow.triangle.2.circlepath") }
                        .buttonStyle(.bordered)
                }
            }
        }
        .font(.footnote).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20))
    }
}

private struct XMGoSettingsView: View {
    @AppStorage("xmgo.tint.choice") private var tintChoice = "black"
    @AppStorage("xmgo.tint.custom") private var customTint = "#DCAA61"
    @AppStorage("xmgo.module.sound.open") private var soundOpen = true
    @AppStorage("xmgo.module.equalizer.open") private var equalizerOpen = false
    @AppStorage("xmgo.module.quick.open") private var quickOpen = false
    @Environment(HeadphoneStore.self) private var store
    @State private var appearanceOpen = true
    @State private var homeOpen = false
    @State private var experimentalOpen = false
    @State private var aboutOpen = false

    private var customColor: Binding<Color> {
        Binding(get: { Color(xmHex: customTint) }, set: { customTint = $0.xmHexString() })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Color.clear.frame(height: 22).accessibilityHidden(true)
                CollapsibleGlassCard(title: "Appearance", systemImage: "paintpalette.fill", expanded: $appearanceOpen) {
                    VStack(spacing: 14) {
                        HStack(spacing: 14) {
                            tintSwatch(choice: "black", color: Color(xmHex: "#DCAA61"), label: "Black")
                            tintSwatch(choice: "silver", color: Color(xmHex: "#D4D4D4"), label: "Silver")
                            tintSwatch(choice: "blue", color: Color(xmHex: "#6686A8"), label: "Blue")
                            tintSwatch(choice: "lavender", color: Color(xmHex: "#B8A0CF"), label: "Lavender")
                            tintSwatch(choice: "beige", color: Color(xmHex: "#F0DDBD"), label: "Beige")
                            customSwatch
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text("The tint is used for the controls, the sliders and the headset icon.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                CollapsibleGlassCard(title: "Home", systemImage: "rectangle.3.group", expanded: $homeOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Modules open at launch").font(.subheadline).foregroundStyle(.secondary)
                        Toggle("Sound Control", isOn: $soundOpen)
                        Toggle("Equalizer", isOn: $equalizerOpen)
                        Toggle("Quick Settings", isOn: $quickOpen)
                    }
                }
                CollapsibleGlassCard(title: "Experimental Features", systemImage: "flask", expanded: $experimentalOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Power-on sound mode")
                            .font(.subheadline.weight(.semibold))
                        PowerOnModePicker(selection: Binding(
                            get: { store.powerOnSoundMode },
                            set: { store.setPowerOnSoundMode($0) }
                        ))
                        Text("Sony doesn't save this on the headset. XMGo reapplies the selected mode as soon as it detects the headset turning on, even while the app is in the background.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                CollapsibleGlassCard(title: "About", systemImage: "info.circle", expanded: $aboutOpen) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Initially made for my XM4, but I don't have any other headphones to test on the other Sony models, so let me know if you run into any bugs or issues.")
                            .foregroundStyle(.secondary)
                        Text("Questions, feedback or bug reports: [@rmxptfl](https://x.com/rmxptfl) on X · [tlfares](https://github.com/tlfares) on GitHub")
                        Divider()
                        Text("I don't drink coffee, but if you like the app, you can still [buy me a coffee](https://buymeacoffee.com/tlfares).")
                    }
                    .font(.footnote)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private func tintSwatch(choice: String, color: Color, label: String) -> some View {
        Button {
            withAnimation(.smooth) { tintChoice = choice }
        } label: {
            Circle()
                .fill(color)
                .frame(width: 38, height: 38)
                .overlay { if tintChoice == choice { Image(systemName: "checkmark").font(.headline.weight(.bold)).foregroundStyle(.black) } }
                .overlay { Circle().stroke(.white.opacity(tintChoice == choice ? 0.9 : 0.28), lineWidth: tintChoice == choice ? 2 : 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var customSwatch: some View {
        ZStack {
            // The system ColorPicker renders its swatch at a fixed intrinsic
            // size that ignores frame. Scale it up so it fills the 40 pt ring.
            ColorPicker("Custom Color", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(1.35)
                .frame(width: 40, height: 40)
                .onChange(of: customTint) { _, _ in tintChoice = "custom" }
        }
        .overlay {
            Circle().stroke(.white.opacity(tintChoice == "custom" ? 0.9 : 0.28), lineWidth: tintChoice == "custom" ? 2 : 1)
                .frame(width: 40, height: 40)
                .allowsHitTesting(false)
        }
        .accessibilityLabel("Custom Color")
    }
}

/// AirPods Pro-style segmented bar, identical to the one on the home screen
/// (NoiseModePicker): a capsule-fill highlight that slides between modes.
private struct PowerOnModePicker: View {
    @Binding var selection: PowerOnSoundModeSetting
    @Namespace private var selectionAnimation

    var body: some View {
        HStack(spacing: 4) {
            ForEach(PowerOnSoundModeSetting.allCases) { setting in
                Button {
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.82)) { selection = setting }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: setting.symbol).font(.headline)
                        Text(setting.rawValue)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 60)
                    .padding(.horizontal, 4)
                    .foregroundStyle(selection == setting ? .primary : .secondary)
                    .background {
                        if selection == setting {
                            Capsule()
                                .fill(.tint.opacity(0.30))
                                .matchedGeometryEffect(id: "selectedPowerOnMode", in: selectionAnimation)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityLabel("Power-on sound mode")
    }
}
