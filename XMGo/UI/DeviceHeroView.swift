import SwiftUI

struct DeviceHeroView: View {
    @Environment(HeadphoneStore.self) private var store
    @AppStorage("xmgo.tint.choice") private var tintChoice = "black"
    @AppStorage("xmgo.tint.custom") private var customTint = "#DCAA61"

    var body: some View {
        GlassCard {
            VStack(spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.headphone.name)
                            .font(.title2.bold())
                        Text(store.headphone.isDemo ? "Simulator preview" : "Your headset")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(connected: store.isConnected)
                }

                Image(systemName: "headphones")
                    .font(.system(size: 92, weight: .ultraLight))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Color(xmHex: XMColorTheme.hex(choice: tintChoice, custom: customTint)))
                    .frame(height: 118)
                    .accessibilityHidden(true)

                HStack {
                    Label("\(store.headphone.batteryLevel) %", systemImage: batterySymbol)
                    Spacer()
                    Label(store.headphone.connectionQuality, systemImage: "wave.3.right")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    private var batterySymbol: String {
        switch store.headphone.batteryLevel {
        case 76...: "battery.100percent"
        case 51...: "battery.75percent"
        case 26...: "battery.50percent"
        default: "battery.25percent"
        }
    }
}
