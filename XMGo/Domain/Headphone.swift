import Foundation

enum ConnectionState: Equatable {
    case idle, scanning, connecting, connected, unavailable(String)
}

enum NoiseControlMode: String, CaseIterable, Identifiable, Codable {
    case noiseCancelling = "Noise Cancelling"
    case ambient = "Ambient"
    case off = "Off"

    var id: Self { self }
    var symbol: String {
        switch self {
        case .noiseCancelling: "person.fill"
        case .ambient: "waveform.and.person"
        case .off: "person.wave.2.inward.fill"
        }
    }
}

struct EqualizerSettings: Equatable, Codable {
    static let frequencies = ["400", "1k", "2.5k", "6.3k", "16k"]
    var bands: [Double] = [0, 0, 0, 0, 0]
    var clearBass: Double = 0
}

struct HeadphoneState: Equatable {
    var name = "WH-1000XM4"
    var batteryLevel = 0
    var noiseControl: NoiseControlMode = .noiseCancelling
    var ambientLevel = 10
    var focusOnVoice = false
    var equalizer = EqualizerSettings()
    var speakToChat = false
    var wearingDetection = true
    var connectionQuality = "Stable"
    var isDemo = false
}

struct DiscoveredHeadphone: Identifiable, Equatable {
    let id: UUID
    let name: String
    let signal: Int

    var isRemembered: Bool { signal == Int.min }
}

/// Experimental "power-on sound mode": the noise-control mode XMGo reapplies
/// whenever it detects the headset turning on. Sony doesn't store this on the
/// device, so the app owns the behavior.
enum PowerOnSoundModeSetting: String, CaseIterable, Identifiable {
    case lastUsed = "Last used"
    case noiseCancelling = "ANC/Default"
    case ambient = "Ambient"
    case off = "Off"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .lastUsed: "clock.arrow.circlepath"
        case .noiseCancelling: "person.fill"
        case .ambient: "waveform.and.person"
        case .off: "person.wave.2.inward.fill"
        }
    }

    /// The noise-control mode to apply, or nil when the choice means "no app
    /// action" (keep last used, or the headset's own default which is already
    /// Noise Cancelling).
    var noiseControlMode: NoiseControlMode? {
        switch self {
        case .lastUsed, .noiseCancelling: nil
        case .ambient: .ambient
        case .off: .off
        }
    }
}
