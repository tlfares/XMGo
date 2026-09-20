import SwiftUI

enum XMTheme {
    // The black XM4 needs a visible accent; its champagne/gold hardware detail
    // is a better default than putting blue light on an otherwise black UI.
    static let tint = Color(red: 0.86, green: 0.67, blue: 0.38)
    static let background = Color.black
}

enum XMColorTheme {
    static func hex(choice: String, custom: String) -> String {
        switch choice {
        // The black WH-1000XM4 uses its champagne hardware accent so controls
        // stay visible against XMGo's black background.
        case "black": "#DCAA61"
        case "silver": "#D4D4D4"
        case "blue": "#6686A8"
        case "lavender": "#B8A0CF"
        case "beige": "#F0DDBD"
        case "custom": custom
        default: "#DCAA61"
        }
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
    }
}

struct CollapsibleGlassCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content
    @Binding private var isExpanded: Bool

    init(title: String, systemImage: String, expanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
        _isExpanded = expanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage).font(.headline)
                    Text(title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
                    .padding(.top, 18)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 28))
        .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.85), value: isExpanded)
    }
}

struct XMBackgroundView: View {
    let base: Color
    let accent: Color
    let weight: Double
    let spread: Double

    var body: some View {
        let start = max(0, weight - (0.01 + spread * 0.49))
        let end = min(1, weight + (0.01 + spread * 0.49))
        LinearGradient(
            gradient: Gradient(stops: [
                .init(color: base, location: 0),
                .init(color: base, location: start),
                .init(color: accent, location: end),
                .init(color: accent, location: 1),
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(.black.opacity(0.06))
        .ignoresSafeArea()
    }
}

extension Color {
    init(xmHex: String) {
        let hex = xmHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    func xmHexString() -> String {
        let components = UIColor(self).cgColor.components ?? [0, 0, 0]
        let r = Int((components.count > 0 ? components[0] : 0) * 255)
        let g = Int((components.count > 1 ? components[1] : components[0]) * 255)
        let b = Int((components.count > 2 ? components[2] : components[0]) * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

struct StatusPill: View {
    let connected: Bool

    var body: some View {
        Group {
            if connected {
                Label("Connected", systemImage: "checkmark")
            } else {
                Text("Offline")
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(connected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
    }
}
