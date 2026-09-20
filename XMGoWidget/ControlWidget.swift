import SwiftUI
import WidgetKit
import AppIntents

/// Control Center module for XMGo. A single circular button whose label shows
/// the current mode; tapping cycles to the next one.
struct ModeControl: ControlWidget {
    static let kind = "com.fares.xmgo.mode"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: ModeProvider()) { mode in
            ControlWidgetButton(action: CycleModeIntent()) {
                Label(mode.rawValue, systemImage: mode.symbol)
            }
        }
        .displayName("Switch mode")
        .description("Cycles between Noise Cancelling, Ambient and Off on your XMGo headset.")
    }
}

struct ModeProvider: ControlValueProvider {
    typealias Value = SharedMode

    var previewValue: SharedMode { .noiseCancelling }

    func currentValue() async throws -> SharedMode {
        XMGoShared.currentMode
    }
}

/// Direct button for each sound mode: these read as separate items in the
/// Control Center gallery, so they can sit side by side. Each resizes
/// circular → 2x1 → 4x1 with its label.
struct NoiseCancellingControl: ControlWidget {
    static let kind = "com.fares.xmgo.nc"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: SetNoiseCancellingIntent()) {
                Label(SharedMode.noiseCancelling.rawValue, systemImage: SharedMode.noiseCancelling.symbol)
            }
        }
        .displayName("Noise Cancelling")
        .description("Switch your XMGo headset to Noise Cancelling.")
    }
}

struct AmbientControl: ControlWidget {
    static let kind = "com.fares.xmgo.ambient"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: SetAmbientIntent()) {
                Label(SharedMode.ambient.rawValue, systemImage: SharedMode.ambient.symbol)
            }
        }
        .displayName("Ambient")
        .description("Switch your XMGo headset to Ambient sound.")
    }
}

struct OffControl: ControlWidget {
    static let kind = "com.fares.xmgo.off"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: SetOffIntent()) {
                Label(SharedMode.off.rawValue, systemImage: SharedMode.off.symbol)
            }
        }
        .displayName("Off")
        .description("Switch your XMGo headset to Off.")
    }
}

@main
struct XMGoControlsBundle: WidgetBundle {
    var body: some Widget {
        ModeControl()
        NoiseCancellingControl()
        AmbientControl()
        OffControl()
    }
}