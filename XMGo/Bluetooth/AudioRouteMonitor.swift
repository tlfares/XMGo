@preconcurrency import AVFAudio
import Foundation

@MainActor
final class AudioRouteMonitor {
    var onHeadphoneRouteChange: ((String?) -> Void)?
    private var observer: NSObjectProtocol?

    func start() {
        // XMGo is a controller, never an audio player. Keep any implicit
        // session activation non-interrupting so opening the app cannot pause
        // Music, Podcasts or another playback app.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, options: [.mixWithOthers, .allowBluetoothHFP])
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.publishCurrentRoute() }
        }
        publishCurrentRoute()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func publishCurrentRoute() {
        let bluetooth = AVAudioSession.sharedInstance().currentRoute.outputs.first { output in
            switch output.portType {
            case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
                true
            default:
                false
            }
        }
        onHeadphoneRouteChange?(bluetooth?.portName)
    }
}
