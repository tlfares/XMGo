import Foundation
import Observation

@MainActor
@Observable
final class HeadphoneStore {
    var connection: ConnectionState = .idle
    var headphone = HeadphoneState()
    var discovered: [DiscoveredHeadphone] = []
    var showsDevicePicker = false
    var lastError: String?
    var canControl = false
    var controlMessage: String?

    private let bluetooth = BluetoothController()
    private let audioRoute = AudioRouteMonitor()
    private let sonyControl = SonyControlSession()
    private var ambientLevelCommit: DispatchWorkItem?
    private var controlRetry: DispatchWorkItem?
    private var selfHealTimer: Timer?
    private var healTicks = 0
    private let powerOnModeKey = "xmgo.experimental.powermode"
    private let lastSonyConnectionIDKey = "xmgo.lastSonyConnectionID"
    private var powerOnApplyPending = false
    /// A mode change requested from Control Center, applied once the channel is
    /// ready. The app process owns the Sony link, so requests arrive through a
    /// Darwin notification and are queued here until they can be sent.
    private var pendingRemoteMode: NoiseControlMode?

    /// connectionID of the Sony accessory at the most recent time we saw it.
    /// Persisted so a relaunch can tell "still the same session" (app was just
    /// reopened) from "reconnected since" (a real power-on happened in between).
    private var lastSonyConnectionID: Int {
        get { UserDefaults.standard.integer(forKey: lastSonyConnectionIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastSonyConnectionIDKey) }
    }

    init() {
        bluetooth.onStateChange = { [weak self] state in
            guard let self else { return }
            // A new discovery pass must not make an actively routed headset
            // appear disconnected just because it stopped advertising over LE.
            if connection == .connected, state == .scanning || state == .idle { return }
            connection = state
        }
        bluetooth.onDiscovery = { [weak self] device in
            guard let self else { return }
            if let index = discovered.firstIndex(where: { $0.id == device.id }) {
                discovered[index] = device
            } else {
                discovered.append(device)
            }
        }
        bluetooth.onConnected = { [weak self] name in
            self?.headphone.name = name
            self?.headphone.batteryLevel = 100
            self?.showsDevicePicker = false
        }
        bluetooth.onControlAvailability = { [weak self] available, message in
            // ExternalAccessory is the actual Sony channel on iOS. The BLE
            // discovery result alone must not decide control availability.
            if available { self?.canControl = true; self?.controlMessage = nil }
        }
        sonyControl.onReady = { [weak self] ready, _ in
            guard let self else { return }
            self.canControl = ready
            if ready {
                self.controlRetry?.cancel()
                self.controlMessage = nil
                self.stopSelfHeal()
                let id = self.sonyControl.sonyConnectionID
                if id > 0 { self.lastSonyConnectionID = id }
                if self.powerOnApplyPending {
                    self.powerOnApplyPending = false
                    // Let the initial state-request burst (GETs) finish settling
                    // before sending the switch, so the stop-and-wait link does
                    // not drop our SET behind the queued queries.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                        self?.applyPowerOnSoundMode()
                    }
                }
                if self.pendingRemoteMode != nil {
                    self.pushRemoteMode()
                }
            } else {
                self.controlMessage = self.unavailableMessage()
                if self.isConnected { self.startSelfHeal() }
            }
        }
        // Power-on detection is iOS-driven: only a fresh EAAccessoryDidConnect
        // counts as the headset waking up. Cold-starting the app while the
        // headset is already connected must not re-apply anything.
        sonyControl.onPowerOn = { [weak self] in
            guard let self else { return }
            print("[XMGo MDR] power-on detected by iOS")
            self.requestPowerOnApply()
        }
        // A real power-off cancels any apply still pending from an earlier wake.
        sonyControl.onPowerOff = { [weak self] in
            self?.powerOnApplyPending = false
        }
        sonyControl.onUpdate = { [weak self] update in
            guard let self else { return }
            switch update {
            case let .battery(level):
                headphone.batteryLevel = level
            case let .noiseControl(mode, ambientLevel, focusOnVoice):
                headphone.noiseControl = mode
                headphone.ambientLevel = ambientLevel
                headphone.focusOnVoice = focusOnVoice
                // Keep the Control Center module in sync with the real state.
                XMGoShared.updateCurrentMode(SharedMode(rawValue: mode.rawValue) ?? .noiseCancelling)
            case let .equalizer(equalizer):
                headphone.equalizer = equalizer
            case let .speakToChat(enabled):
                headphone.speakToChat = enabled
            case let .wearingDetection(enabled):
                headphone.wearingDetection = enabled
            }
        }
        audioRoute.onHeadphoneRouteChange = { [weak self] name in
            guard let self else { return }
            if let name, name.localizedCaseInsensitiveContains("WH-") ||
                name.localizedCaseInsensitiveContains("WF-") ||
                name.localizedCaseInsensitiveContains("Sony") {
                headphone.name = name
                if connection != .connecting { connection = .connected }
                bluetooth.reconnectControlLink()
                if !canControl { startSelfHeal() }
            } else if connection == .connected && !headphone.isDemo {
                connection = .idle
            }
        }

        if let rawID = UserDefaults.standard.string(forKey: "rememberedHeadphoneID"),
           let id = UUID(uuidString: rawID) {
            let name = UserDefaults.standard.string(forKey: "rememberedHeadphoneName") ?? "WH-1000XM4"
            discovered = [.init(id: id, name: name, signal: Int.min)]
        }
    }

    var isConnected: Bool { connection == .connected || canControl }

    /// Experimental: the sound mode to reapply as soon as the headset turns on.
    var powerOnSoundMode: PowerOnSoundModeSetting {
        get { UserDefaults.standard.string(forKey: powerOnModeKey).flatMap(PowerOnSoundModeSetting.init(rawValue:)) ?? .noiseCancelling }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: powerOnModeKey) }
    }

    /// Stores the power-on sound mode. This is a wake-up preference, not an
    /// immediate switch: it is applied only when a power-on is detected.
    func setPowerOnSoundMode(_ setting: PowerOnSoundModeSetting) {
        powerOnSoundMode = setting
    }

    /// Applies the chosen power-on sound mode after a power-on that iOS
    /// determined itself (EAAccessoryDidConnect). Runs in the background too,
    /// thanks to the external-accessory background mode.
    private func applyPowerOnSoundMode() {
        guard canControl,
              sonyControl.hasConnectedSonyAccessory || sonyControl.hasAuthorizedAccessory,
              let mode = powerOnSoundMode.noiseControlMode else { return }
        print("[XMGo MDR] applying power-on mode \(mode.rawValue)")
        sonyControl.setNoiseControl(mode, ambientLevel: headphone.ambientLevel, focusOnVoice: headphone.focusOnVoice)
    }

    /// Marks a power-on as needing the sound mode, applied once the channel is
    /// ready. No-op while already in control; falls back to onReady otherwise.
    private func requestPowerOnApply() {
        powerOnApplyPending = true
        if canControl {
            powerOnApplyPending = false
            applyPowerOnSoundMode()
        }
    }

    /// Handles a power-on that happened while we were not observing (app
    /// terminated or suspended). iOS assigns a fresh connectionID to every
    /// connection session, so "new ID since our last launch" means the headset
    /// actually reconnected again. A relaunch with the headset still on keeps
    /// the same ID and must not reapply anything.
    private func detectPowerOnWhileUnobserved() {
        let current = sonyControl.sonyConnectionID
        guard current > 0 else { return }
        guard lastSonyConnectionID > 0, current != lastSonyConnectionID else {
            lastSonyConnectionID = current
            return
        }
        print("[XMGo MDR] headset reconnected since last launch (connectionID \(lastSonyConnectionID) -> \(current))")
        lastSonyConnectionID = current
        requestPowerOnApply()
    }

    /// Listens for Control Center taps. The module runs in a separate process,
    /// so a Darwin notification is the handshake: it wakes the app (even when
    /// suspended) and triggers `handleRemoteWake()`. Terminated apps pick the
    /// request up on next launch instead.
    private func startWakeObserver() {
        let token = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            token,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let store = Unmanaged<HeadphoneStore>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in store.handleRemoteWake() }
            },
            XMGoShared.wakeNotification.rawValue,
            nil,
            .deliverImmediately
        )
    }

    /// A Control Center tap: consume the requested mode and forward it once the
    /// Sony channel is usable.
    func handleRemoteWake() {
        guard let shared = XMGoShared.consumePendingMode(),
              let target = NoiseControlMode(rawValue: shared.rawValue) else { return }
        print("[XMGo MDR] Control Center requested \(shared.rawValue)")
        pendingRemoteMode = target
        pushRemoteMode()
    }

    @MainActor
    private func pushRemoteMode() {
        guard canControl, pendingRemoteMode != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let mode = self.pendingRemoteMode else { return }
            self.pendingRemoteMode = nil
            print("[XMGo MDR] applying Control Center mode \(mode.rawValue)")
            self.sonyControl.setNoiseControl(mode, ambientLevel: self.headphone.ambientLevel, focusOnVoice: self.headphone.focusOnVoice)
        }
    }

    func start() {
#if targetEnvironment(simulator)
        connectDemo()
#else
        audioRoute.start()
        bluetooth.start()
        sonyControl.startMonitoring()
        detectPowerOnWhileUnobserved()
        startWakeObserver()
        handleRemoteWake()
        sonyControl.connect(preferredNamePrefix: accessoryNamePrefix)
        // Auto-heal: if the headset is routed for audio but iOS never exposes
        // the control channel, rebuild the Bluetooth link once shortly after
        // launch so iOS re-runs the iAP2 identification by itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.needsRepair else { return }
            self.repairControlLink()
        }
#endif
    }

    /// Model prefix used to filter the system Bluetooth accessory picker,
    /// matching how Sound Connect narrows the list to Sony headphones.
    private var accessoryNamePrefix: String? {
        let name = headphone.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        for prefix in ["WH-", "WF-", "WI-", "MDR-", "LinkBuds", "SRS-", "BRAVIA"]
        where name.hasPrefix(prefix) {
            return prefix
        }
        return nil
    }

    func retryControlNow() {
        guard !headphone.isDemo else { return }
        controlRetry?.cancel()
        canControl = false
        controlMessage = "Connecting to the headset…"
        // Snapshot the EA state now so the heal loop can act without delay.
        bluetooth.reconnectControlLink()
        sonyControl.connect(preferredNamePrefix: accessoryNamePrefix)
        startSelfHeal()
    }

    private func unavailableMessage() -> String {
        let audioRouted = connection == .connected
        return (sonyControl.hasConnectedSonyAccessory || audioRouted)
            ? "The headset is connected for audio, but iOS hasn't exposed the control channel yet. XMGo automatically restarts the headset's Bluetooth link (like Sound Connect) to reactivate the channel. Music pauses ~1 sec."
            : "The headset seems out of range or powered off. Turn it on and keep it close."
    }

    /// True when the headset is routed for audio but the MFi control channel is
    /// missing — the case where a BT link rebuild genuinely helps.
    var needsRepair: Bool {
        !headphone.isDemo && connection == .connected && !canControl && !sonyControl.hasAuthorizedAccessory
    }

    /// User-triggered (or auto-heal) full link rebuild: iOS has no API to attach
    /// the control channel to an alive audio link, so we cycle the Bluetooth
    /// link which makes it re-run iAP2 identification.
    func repairControlLink() {
        guard !headphone.isDemo else { return }
        controlRetry?.cancel()
        canControl = false
        controlMessage = "Restarting the Bluetooth link to re-expose the control channel…"
        bluetooth.rebuildLink()
        sonyControl.connect(preferredNamePrefix: accessoryNamePrefix)
        startSelfHeal()
    }

    /// Sound Connect's "Connect" button is a relentless background loop: retry
    /// the Sony channel whenever iOS exposes it, and periodically cycle the
    /// Bluetooth link so iOS re-runs the iAP2 identification. Mirror that here.
    private func startSelfHeal() {
        guard selfHealTimer == nil, isConnected, !canControl else { return }
        healTicks = 0
        print("[XMGo MDR] self-heal loop started")
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.selfHealTick() }
        }
        selfHealTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopSelfHeal() {
        selfHealTimer?.invalidate()
        selfHealTimer = nil
    }

    private func selfHealTick() {
        guard isConnected, !canControl else {
            stopSelfHeal()
            return
        }
        healTicks += 1
        if sonyControl.hasAuthorizedAccessory {
            // iOS just exposed the channel — reopen the session right now.
            sonyControl.connect(preferredNamePrefix: accessoryNamePrefix)
        }
        switch healTicks {
        case 8: // every ~8 s: re-request the LE link so iOS keeps the device "ours"
            bluetooth.reconnectControlLink()
        case 25: // every ~25 s: full cancel+reconnect so iOS re-runs identification
            print("[XMGo BLE] self-heal: cycling the Bluetooth link")
            bluetooth.rebuildLink()
            healTicks = 0
        default:
            break
        }
    }

    func presentScanner() {
        showsDevicePicker = true
        bluetooth.scan()
    }

    func connect(_ device: DiscoveredHeadphone) { bluetooth.connect(id: device.id) }

    func connectDemo() {
        headphone = HeadphoneState(batteryLevel: 78, isDemo: true)
        connection = .connected
        canControl = true
        controlMessage = nil
        showsDevicePicker = false
    }

    func setNoiseControl(_ mode: NoiseControlMode) {
        guard canControl else { return }
        pendingRemoteMode = nil
        ambientLevelCommit?.cancel()
        ambientLevelCommit = nil
        headphone.noiseControl = mode
        sonyControl.setNoiseControl(mode, ambientLevel: headphone.ambientLevel, focusOnVoice: headphone.focusOnVoice)
    }
    func setAmbientLevel(_ level: Int) {
        guard canControl else { return }
        headphone.ambientLevel = level
        // SwiftUI emits one value for each tick while dragging. The Sony V1
        // channel is stop-and-wait, so coalesce that gesture into one write.
        ambientLevelCommit?.cancel()
        let commit = DispatchWorkItem { [weak self] in
            guard let self, self.canControl, self.headphone.noiseControl == .ambient else { return }
            self.sonyControl.setNoiseControl(.ambient, ambientLevel: self.headphone.ambientLevel, focusOnVoice: self.headphone.focusOnVoice)
        }
        ambientLevelCommit = commit
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: commit)
    }
    func updateBand(_ index: Int, value: Double) {
        guard headphone.equalizer.bands.indices.contains(index) else { return }
        headphone.equalizer.bands[index] = value
        if canControl { sonyControl.setEqualizer(headphone.equalizer) }
    }

    func applyEqualizer(_ equalizer: EqualizerSettings) {
        guard canControl else { return }
        headphone.equalizer = equalizer
        sonyControl.setEqualizer(equalizer)
    }

    func setFocusOnVoice(_ enabled: Bool) {
        guard canControl else { return }
        headphone.focusOnVoice = enabled
        sonyControl.setNoiseControl(headphone.noiseControl, ambientLevel: headphone.ambientLevel, focusOnVoice: enabled)
    }

    func setClearBass(_ value: Double) {
        guard canControl else { return }
        headphone.equalizer.clearBass = value
        sonyControl.setEqualizer(headphone.equalizer)
    }

    func setSpeakToChat(_ enabled: Bool) {
        guard canControl else { return }
        headphone.speakToChat = enabled
        sonyControl.setSpeakToChat(enabled)
    }

    func setWearingDetection(_ enabled: Bool) {
        guard canControl else { return }
        headphone.wearingDetection = enabled
        sonyControl.setWearingDetection(enabled)
    }
}
