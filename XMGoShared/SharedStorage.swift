import Foundation
import WidgetKit

/// The noise-control modes, shared between the app and the Control Center
/// module. Raw values match `NoiseControlMode` in the app so the mapping is
/// lossless.
enum SharedMode: String, CaseIterable, Sendable {
    case noiseCancelling = "Noise Cancelling"
    case ambient = "Ambient"
    case off = "Off"

    nonisolated var symbol: String {
        switch self {
        case .noiseCancelling: "person.fill"
        case .ambient: "waveform.and.person"
        case .off: "person.wave.2.inward.fill"
        }
    }

    /// The mode a tap on the Control Center button cycles to.
    nonisolated var next: SharedMode {
        switch self {
        case .noiseCancelling: .ambient
        case .ambient: .off
        case .off: .noiseCancelling
        }
    }
}

enum XMGoShared {
    /// App Group shared by the app and the control extension. Must be enabled
    /// under Signing & Capabilities for both targets.
    nonisolated static let appGroupID = "group.com.fares.xmgo"
    /// Darwin notify name used to wake the running app when a control is tapped.
    nonisolated static let wakeNotification = CFNotificationName("xmgo.cc.wake" as CFString)

    nonisolated private static let currentModeKey = "xmgo.cc.currentMode"
    nonisolated private static let pendingModeKey = "xmgo.cc.pendingMode"

    nonisolated private static var store: UserDefaults? { UserDefaults(suiteName: appGroupID) }

    nonisolated static var currentMode: SharedMode {
        guard let store else { return .noiseCancelling }
        return store.string(forKey: currentModeKey).flatMap(SharedMode.init(rawValue:)) ?? .noiseCancelling
    }

    nonisolated static func updateCurrentMode(_ mode: SharedMode) {
        guard let store else { return }
        store.set(mode.rawValue, forKey: currentModeKey)
        Task { @MainActor in
            ControlCenter.shared.reloadAllControls()
        }
    }

    nonisolated static func consumePendingMode() -> SharedMode? {
        guard let store else { return nil }
        let raw = store.string(forKey: pendingModeKey)
        if raw != nil { store.removeObject(forKey: pendingModeKey) }
        return raw.flatMap(SharedMode.init(rawValue:))
    }

    /// Records a mode change requested from Control Center and wakes the app so
    /// it can forward the command to the headset even while suspended.
    nonisolated static func requestMode(_ mode: SharedMode) {
        guard let store else { return }
        store.set(mode.rawValue, forKey: pendingModeKey)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            wakeNotification, nil, nil, true)
    }

    /// Optimistically updates the shown mode and schedules the real change.
    /// Used by the per-mode Control Center buttons.
    nonisolated static func setMode(_ mode: SharedMode) {
        updateCurrentMode(mode)
        requestMode(mode)
    }
}