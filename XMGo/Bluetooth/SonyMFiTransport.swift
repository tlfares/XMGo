import ExternalAccessory
import Foundation

/// Production transport for a Sony-authorized MFi/iAP protocol.
///
/// Sony must provide the reverse-DNS protocol name and authorize XMGo's
/// bundle identifier before iOS exposes a matching EAAccessory/EASession.
@MainActor
final class SonyMFiTransport: NSObject, HeadphoneTransport, StreamDelegate {
    var onPacket: (@Sendable (Data) -> Void)?
    var onAccessoryAvailable: (() -> Void)?
    var onAccessoryDisconnected: (() -> Void)?

    private var session: EASession?
    private var inputBuffer = Data()
    private var outputBuffer = Data()
    private var connectObserver: NSObjectProtocol?
    private var disconnectObserver: NSObjectProtocol?

    var configuredProtocols: [String] {
        Bundle.main.object(forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols") as? [String] ?? []
    }

    static let sonyNamePrefixes = ["WH-", "WF-", "WI-", "MDR-", "LinkBuds", "SRS-", "BRAVIA", "Sony"]

    var connectedAccessories: [EAAccessory] {
        EAAccessoryManager.shared().connectedAccessories
    }

    /// True when iOS exposes ANY accessory named like a Sony headset, even if
    /// the MFi protocol has not been authenticated for XMGo yet.
    var hasConnectedSonyAccessory: Bool {
        connectedAccessories.contains { accessory in
            Self.sonyNamePrefixes.contains { accessory.name.uppercased().hasPrefix($0.uppercased()) }
        }
    }

    /// `connectionID` of the connected Sony accessory (0 when none). iOS gives
    /// every accessory connection a fresh ID, so a change means the headset
    /// reconnected (powered on again) since we last saw it.
    var sonyConnectionID: Int {
        connectedAccessories.first { accessory in
            Self.sonyNamePrefixes.contains { accessory.name.uppercased().hasPrefix($0.uppercased()) }
        }?.connectionID ?? 0
    }

    /// True when iOS currently exposes a paired Sony accessory for one of the
    /// declared MFi protocols. While this is false the headset may still be
    /// connected for audio (A2DP/HFP) but cannot serve the control channel.
    var hasAuthorizedAccessory: Bool {
        guard !configuredProtocols.isEmpty else { return false }
        return EAAccessoryManager.shared().connectedAccessories.contains { accessory in
            accessory.protocolStrings.contains { configuredProtocols.contains($0) }
        }
    }

    /// Presents the system Bluetooth accessory picker.
    ///
    /// This mirrors the "Connect" button of Sony Sound Connect: when iOS has
    /// paired the headset for audio but has not authenticated the MFi link,
    /// selecting the headset in this picker is what makes iOS expose it in
    /// `connectedAccessories` and fire `EAAccessoryDidConnect`.
    func presentConnectionPicker(namePrefix: String?) {
        let filter = namePrefix.flatMap { prefix in
            prefix.isEmpty ? nil : NSPredicate(format: "SELF BEGINSWITH %@", prefix)
        }
        EAAccessoryManager.shared().showBluetoothAccessoryPicker(withNameFilter: filter, completion: { _ in })
    }

    func openAuthorizedAccessory(preferredNamePrefix: String?) throws {
        closeSession()
        guard !configuredProtocols.isEmpty else {
            throw SonyMFiError.missingProtocolConfiguration
        }

        // Prefer the accessory whose name matches the remembered headset,
        // then fall back to any authorized Sony accessory.
        let candidates = connectedAccessories
        let preferred = preferredNamePrefix.flatMap { prefix in
            candidates.filter { $0.name.uppercased().hasPrefix(prefix.uppercased()) }
        } ?? []
        let ordered = preferred + candidates.filter { accessory in
            !preferred.contains { $0 === accessory }
        }

        for accessory in ordered {
            for protocolName in configuredProtocols where accessory.protocolStrings.contains(protocolName) {
                if let session = EASession(accessory: accessory, forProtocol: protocolName) {
                    self.session = session
                    session.inputStream?.delegate = self
                    session.outputStream?.delegate = self
                    session.inputStream?.schedule(in: .main, forMode: .common)
                    session.outputStream?.schedule(in: .main, forMode: .common)
                    session.inputStream?.open()
                    session.outputStream?.open()
                    attemptFlush()
                    return
                }
            }
        }
        let names = candidates.map { $0.name }.joined(separator: ", ")
        let protos = candidates.flatMap { $0.protocolStrings }.joined(separator: ", ")
        print("[XMGo MDR] no authorized accessory — connected: \(names.isEmpty ? "(none)" : names) protocols: \(protos.isEmpty ? "(none)" : protos)")
        throw SonyMFiError.noAuthorizedAccessory
    }

    func startMonitoring() {
        EAAccessoryManager.shared().registerForLocalNotifications()
        connectObserver = NotificationCenter.default.addObserver(
            forName: .EAAccessoryDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onAccessoryAvailable?() }
        }
        disconnectObserver = NotificationCenter.default.addObserver(
            forName: .EAAccessoryDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onAccessoryDisconnected?() }
        }
    }

    func close() {
        if let connectObserver { NotificationCenter.default.removeObserver(connectObserver) }
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
        connectObserver = nil
        disconnectObserver = nil
        EAAccessoryManager.shared().unregisterForLocalNotifications()
        closeSession()
    }

    /// Closes only the active data session (if any) without touching the
    /// accessory observers, so the retry loop can re-open it cleanly.
    func closeDataSession() {
        closeSession()
    }

    private func closeSession() {
        session?.inputStream?.close()
        session?.outputStream?.close()
        session = nil
        inputBuffer.removeAll(keepingCapacity: true)
    }

    func send(_ packet: Data) async throws {
        guard session?.outputStream != nil else { throw SonyMFiError.notOpen }
        // Right after opening an EASession the output stream may not accept
        // bytes yet. Queue and flush as soon as space is available instead of
        // silently dropping the INIT/GET frames (which left the app without
        // controls while the headset was on).
        outputBuffer.append(packet)
        attemptFlush()
    }

    private func attemptFlush() {
        guard let output = session?.outputStream, !outputBuffer.isEmpty, output.hasSpaceAvailable else { return }
        let written = outputBuffer.withUnsafeBytes { bytes -> Int in
            guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.write(base, maxLength: outputBuffer.count)
        }
        if written > 0 {
            outputBuffer.removeFirst(written)
        }
    }

    nonisolated func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        if eventCode.contains(.hasBytesAvailable), let input = aStream as? InputStream {
            var bytes = [UInt8](repeating: 0, count: 1024)
            let count = input.read(&bytes, maxLength: bytes.count)
            guard count > 0 else { return }
            let packet = Data(bytes.prefix(count))
            Task { @MainActor [weak self] in self?.onPacket?(packet) }
        } else if eventCode.contains(.hasSpaceAvailable) {
            Task { @MainActor [weak self] in self?.attemptFlush() }
        } else if eventCode == .endEncountered || eventCode == .errorOccurred {
            // The accessory dropped the link; let the retry loop recover.
            Task { @MainActor [weak self] in self?.onAccessoryDisconnected?() }
        }
    }
}

enum SonyMFiError: LocalizedError {
    case missingProtocolConfiguration
    case noAuthorizedAccessory
    case sessionRejected
    case notOpen
    case shortWrite(expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .missingProtocolConfiguration:
            "Sony hasn't provided the MFi protocol name to declare yet."
        case .noAuthorizedAccessory:
            "iOS exposes no Sony headset authorized for XMGo."
        case .sessionRejected:
            "iOS refused the Sony MFi session."
        case .notOpen:
            "The Sony control session is not open."
        case let .shortWrite(expected, actual):
            "Incomplete MFi write (\(actual)/\(expected) bytes)."
        }
    }
}
