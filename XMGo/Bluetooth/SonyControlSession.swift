import Foundation

@MainActor
final class SonyControlSession {
    var onReady: ((Bool, String?) -> Void)?
    var onUpdate: ((SonyControlUpdate) -> Void)?
    /// Fires when iOS itself reports a fresh Sony accessory connection
    /// (EAAccessoryDidConnect), i.e. a real wake-up of the headset, as opposed
    /// to this app simply attaching to a headset that was already connected.
    var onPowerOn: (() -> Void)?
    /// Fires when iOS reports the Sony accessory going away.
    var onPowerOff: (() -> Void)?

    private let transport = SonyMFiTransport()
    private let codec = SonyPacketCodec()
    private let parser = SonyFrameParser()
    private var sequence: UInt8 = 0
    private var state = HeadphoneState()
    private var isReady = false
    private var ncSettingType: UInt8 = 0x02
    private var ambientSettingType: UInt8 = 0x01
    private var ambientIdentifier: UInt8 = 0x00
    private var pendingNoiseControl: (mode: NoiseControlMode, ambientLevel: Int, focusOnVoice: Bool, expiresAt: Date)?
    private var isConnecting = false
    private var activationWatchdog: DispatchWorkItem?

    init() {
        transport.onPacket = { [weak self] data in
            Task { @MainActor in self?.receive(data) }
        }
        transport.onAccessoryAvailable = { [weak self] in
            guard let self else { return }
            // Fire on every iOS-reported accessory connection. EAAccessoryDidConnect
            // can be delivered before the accessory is listed in connectedAccessories,
            // so gating here would miss real wake-ups. The store filters with a live
            // Sony check when it comes to applying the mode.
            self.onPowerOn?()
            self.connect()
        }
        transport.onAccessoryDisconnected = { [weak self] in
            guard let self, self.isReady || self.isConnecting else { return }
            self.activationWatchdog?.cancel()
            self.activationWatchdog = nil
            self.isReady = false
            self.isConnecting = false
            self.onPowerOff?()
            self.onReady?(false, "The headset is no longer exposed by iOS. Tap “Connect” to restore the control link.")
        }
    }

    /// Whether iOS currently exposes the Sony accessory for the MFi channel.
    var hasAuthorizedAccessory: Bool { transport.hasAuthorizedAccessory }

    /// Whether iOS sees a Sony-named accessory, even without the MFi channel.
    var hasConnectedSonyAccessory: Bool { transport.hasConnectedSonyAccessory }

    /// connectionID of the current Sony accessory (0 when none).
    var sonyConnectionID: Int { transport.sonyConnectionID }

    /// Asks iOS to (re)establish the MFi link, like Sound Connect's "Connect"
    /// button. Used as a fallback when the accessory is not exposed to XMGo.
    func requestAccessoryConnection(namePrefix: String?) {
        transport.presentConnectionPicker(namePrefix: namePrefix)
    }

    func connect(preferredNamePrefix: String? = nil) {
        guard !isConnecting else { return }
        isConnecting = true
        isReady = false
        activationWatchdog?.cancel()
        activationWatchdog = nil
        onReady?(false, "Connecting to the Sony control channel…")
        do {
            try transport.openAuthorizedAccessory(preferredNamePrefix: preferredNamePrefix)
            sequence = 0
            parser.reset()
            send([0x00, 0x00]) // INIT_REQUEST
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                self?.activate()
            }
        } catch {
            isConnecting = false
            onReady?(false, error.localizedDescription)
        }
    }

    func startMonitoring() { transport.startMonitoring() }

    func setNoiseControl(_ mode: NoiseControlMode, ambientLevel: Int, focusOnVoice: Bool) {
        guard isReady else { return }
        pendingNoiseControl = (mode, ambientLevel, focusOnVoice, Date().addingTimeInterval(1.5))
        let effect: UInt8 = mode == .off ? 0x00 : 0x11
        let ncValue: UInt8 = mode == .noiseCancelling ? 0x02 : 0x00
        let ambient = UInt8(clamping: mode == .ambient ? ambientLevel : 0)
        ambientIdentifier = focusOnVoice ? 0x01 : 0x00
        send([0x68, 0x02, effect, ncSettingType, ncValue, ambientSettingType, ambientIdentifier, ambient])
        // The headset may first notify its previous state. Query after the
        // command has settled, rather than letting that stale notify win.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.send([0x66, 0x02])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) { [weak self] in
            self?.send([0x66, 0x02])
        }
    }

    func setEqualizer(_ equalizer: EqualizerSettings) {
        guard isReady else { return }
        // Sound Connect uses 0...20 values, with 10 as flat. Clear Bass is band 0.
        let bands = [equalizer.clearBass] + equalizer.bands
        let encoded = bands.map { UInt8(clamping: Int($0.rounded()) + 10) }
        send([0x58, 0x01, 0xFF, UInt8(encoded.count)] + encoded)
    }

    func setSpeakToChat(_ enabled: Bool) {
        guard isReady else { return }
        send([0xF8, 0x05, 0x01, enabled ? 0x01 : 0x00])
    }

    func setWearingDetection(_ enabled: Bool) {
        guard isReady else { return }
        let value: UInt8 = enabled ? 0x01 : 0x00
        // Wearing control (play/pause on wear and removal).
        send([0xF8, 0x03, 0x00, value])
        // "Automatic power off when removed from ears" also cuts the audio
        // when the headphones come off. Drive it together with the wearing
        // toggle bit (element 0x10 enabled -> 0x10, disabled -> 0x11).
        send([0xF8, 0x04, 0x01, 0x10, enabled ? 0x10 : 0x11])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.send([0xF6, 0x03])
            self?.send([0xF6, 0x04])
        }
    }

    private func activate() {
        // Do NOT mark the channel ready yet: the headset might never answer
        // (stale EA listing, link dead). Ready is declared by receive() on the
        // first inbound MDR packet. Instead, probe it and arm a watchdog.
        isConnecting = false
        // Sony uses stop-and-wait flow control: the device ACKs each frame
        // before accepting the next one. A tight burst can quietly drop
        // trailing commands, so the initial GETs are staggered.
        let initial: [[UInt8]] = [[0x66, 0x02], [0xF6, 0x05], [0xF6, 0x03], [0x56, 0x01]]
        initial.enumerated().forEach { index, payload in
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.12) { [weak self] in
                self?.send(payload)
            }
        }
        requestBattery(after: 0.2)
        requestBattery(after: 1.2)
        activationWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, !self.isReady else { return }
            print("[XMGo MDR] channel open but silent after 3 s — closing and retrying")
            self.transport.closeDataSession()
            self.onReady?(false, "The Sony control channel is not responding… retrying automatically.")
        }
        activationWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: watchdog)
    }

    private func requestBattery(after delay: TimeInterval = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.send([0x10, 0x00])
        }
    }

    private func send(_ payload: [UInt8]) {
        let frame = codec.frame(payload: payload, sequence: sequence)
        sequence ^= 1
        Task { try? await transport.send(frame) }
    }

    private func receive(_ data: Data) {
        for packet in parser.feed(data) where packet.type == 0x0C || packet.type == 0x0D {
            // Sony V1 uses a stop-and-wait sequence. Acknowledge every
            // command/notification so the headset doesn't replay stale state.
            let ack = codec.frame(payload: [], sequence: packet.sequence ^ 1, dataType: 0x01)
            Task { try? await transport.send(ack) }
            guard let opcode = packet.payload.first else { continue }
            // First inbound MDR packet proves the channel is live. Declare
            // ready here — not optimistically — so a silent/stale session is
            // torn down by the watchdog and retried instead of leaving the UI
            // with controls that never respond.
            if !isReady {
                isReady = true
                isConnecting = false
                activationWatchdog?.cancel()
                activationWatchdog = nil
                onReady?(true, nil)
            }
            switch opcode {
            case 0x67, 0x69:
                parseNoiseControl(packet.payload)
            case 0x11, 0x13:
                // Some units answer the battery ask without a charging byte
                // ([0x11, 0x00, level]); accept that 3-byte form too.
                if packet.payload.count >= 3 {
                    state.batteryLevel = Int(packet.payload[2])
                    onUpdate?(.battery(level: state.batteryLevel))
                }
            case 0xF7, 0xF9:
                guard packet.payload.count >= 4 else { break }
                switch packet.payload[1] {
                case 0x03:
                    state.wearingDetection = packet.payload[3] != 0
                    onUpdate?(.wearingDetection(state.wearingDetection))
                case 0x05:
                    state.speakToChat = packet.payload[3] != 0
                    onUpdate?(.speakToChat(state.speakToChat))
                default:
                    break
                }
            case 0x57, 0x59:
                parseEqualizer(packet.payload)
            default:
                let hex = packet.payload.map { String(format: "%02X", $0) }.joined(separator: " ")
                print("[XMGo MDR] opcode 0x\(String(format: "%02X", opcode)) unhandled: \(hex)")
            }
        }
    }

    private func parseNoiseControl(_ packet: [UInt8]) {
        guard packet.count >= 8, packet[1] == 0x02 else { return }
        let reportedAmbientLevel = Int(packet[7])
        let reportedFocusOnVoice = packet[6] == 0x01
        // A zero ASM level is how the headset represents NC/off. It is not
        // the user's last ambient level, so retain that level for the slider.
        let ambientLevel = reportedAmbientLevel > 0 ? reportedAmbientLevel : state.ambientLevel
        let mode: NoiseControlMode
        if packet[2] == 0 {
            mode = .off
        } else if packet[4] != 0 {
            mode = .noiseCancelling
        } else if reportedAmbientLevel > 0 {
            mode = .ambient
        } else {
            mode = .off
        }
        if let pendingNoiseControl, Date() < pendingNoiseControl.expiresAt,
           (mode != pendingNoiseControl.mode ||
            (mode == .ambient && ambientLevel != pendingNoiseControl.ambientLevel) ||
            (mode == .ambient && reportedFocusOnVoice != pendingNoiseControl.focusOnVoice)) {
            return
        }
        self.pendingNoiseControl = nil
        ncSettingType = packet[3]
        ambientSettingType = packet[5]
        ambientIdentifier = packet[6]
        state.noiseControl = mode
        state.ambientLevel = ambientLevel
        state.focusOnVoice = reportedFocusOnVoice
        onUpdate?(.noiseControl(mode: mode, ambientLevel: state.ambientLevel, focusOnVoice: state.focusOnVoice))
    }

    private func parseEqualizer(_ packet: [UInt8]) {
        guard packet.count >= 5, packet[1] == 0x01 else { return }
        let count = Int(packet[3])
        guard packet.count >= 4 + count else { return }
        let values = packet[4..<(4 + count)].map { Double(Int($0) - 10) }
        if let first = values.first { state.equalizer.clearBass = first }
        if values.count > 1 { state.equalizer.bands = Array(values.dropFirst().prefix(5)) }
        onUpdate?(.equalizer(state.equalizer))
    }
}

enum SonyControlUpdate {
    case battery(level: Int)
    case noiseControl(mode: NoiseControlMode, ambientLevel: Int, focusOnVoice: Bool)
    case equalizer(EqualizerSettings)
    case speakToChat(Bool)
    case wearingDetection(Bool)
}
