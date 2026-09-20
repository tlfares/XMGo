import SwiftUI

struct QuickSettingsCard: View {
    @Environment(HeadphoneStore.self) private var store
    @State private var isExpanded: Bool

    init() {
        _isExpanded = State(initialValue: UserDefaults.standard.object(forKey: "xmgo.module.quick.open") as? Bool ?? false)
    }

    var body: some View {
        @Bindable var store = store
        CollapsibleGlassCard(title: "Quick Settings", systemImage: "gearshape", expanded: $isExpanded) {
            VStack(spacing: 0) {
                Toggle(isOn: Binding(get: { store.headphone.speakToChat }, set: { store.setSpeakToChat($0) })) {
                    Label("Speak-to-Chat", systemImage: "quote.bubble")
                }
                .padding(.bottom, 16)
                Divider()
                Toggle(isOn: Binding(get: { store.headphone.wearingDetection }, set: { store.setWearingDetection($0) })) {
                    Label("Wearing detection", systemImage: "ear.fill")
                }
                .padding(.top, 16)
            }
            .disabled(!store.canControl)
        }
    }
}
