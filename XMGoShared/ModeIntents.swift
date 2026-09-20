import AppIntents

/// Runs when the Control Center module is tapped: cycle NC → Ambient → Off.
/// Written to the shared App Group so the app (even suspended) can forward it
/// to the Sony channel, which lives in the app process.
struct CycleModeIntent: AppIntent {
    static let title: LocalizedStringResource = "Switch sound mode"
    static let description = IntentDescription("Cycles the noise control mode on your XMGo headset.")

    func perform() async throws -> some IntentResult {
        XMGoShared.setMode(XMGoShared.currentMode.next)
        return .result()
    }
}

/// Directly set the headset to Noise Cancelling.
struct SetNoiseCancellingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Noise Cancelling"
    static let description = IntentDescription("Switches your XMGo headset to Noise Cancelling.")

    func perform() async throws -> some IntentResult {
        XMGoShared.setMode(.noiseCancelling)
        return .result()
    }
}

/// Directly set the headset to Ambient sound.
struct SetAmbientIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Ambient"
    static let description = IntentDescription("Switches your XMGo headset to Ambient sound.")

    func perform() async throws -> some IntentResult {
        XMGoShared.setMode(.ambient)
        return .result()
    }
}

/// Directly turn off the headset's noise control.
struct SetOffIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Off"
    static let description = IntentDescription("Switches your XMGo headset to Off (no noise control).")

    func perform() async throws -> some IntentResult {
        XMGoShared.setMode(.off)
        return .result()
    }
}