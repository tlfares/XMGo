import SwiftUI

struct DevicePickerView: View {
    @Environment(HeadphoneStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.discovered.isEmpty {
                    ContentUnavailableView {
                        Label("Searching…", systemImage: "dot.radiowaves.left.and.right")
                    } description: {
                        Text("Turn on your Sony headset and keep it close.")
                    } actions: {
#if targetEnvironment(simulator)
                        Button("Use demo headset") { store.connectDemo() }
#endif
                    }
                } else {
                    List(store.discovered) { device in
                        Button { store.connect(device) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "headphones")
                                    .font(.title2)
                                    .foregroundStyle(XMTheme.tint)
                                VStack(alignment: .leading) {
                                    Text(device.name).font(.headline)
                                    Text(device.isRemembered ? "Remembered headset, reconnecting…" : signalDescription(device.signal))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Nearby Headsets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func signalDescription(_ rssi: Int) -> String {
        if rssi >= -55 { return "Excellent signal" }
        if rssi >= -70 { return "Good signal" }
        return "Weak signal"
    }
}
