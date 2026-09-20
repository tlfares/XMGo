import Foundation

/// Boundary for Sony's reverse-engineered control channel.
/// Packet encoding is deliberately independent from CoreBluetooth so another
/// Apple-approved transport can be added without touching the UI.
protocol HeadphoneTransport: AnyObject {
    var onPacket: (@Sendable (Data) -> Void)? { get set }
    func send(_ packet: Data) async throws
}

enum SonyCommand {
    case noiseControl(NoiseControlMode, ambientLevel: Int, focusOnVoice: Bool)
    case equalizer(EqualizerSettings)
    case speakToChat(Bool)
    case wearingDetection(Bool)
}

enum SonyProtocolError: LocalizedError {
    case controlChannelUnavailable
    case malformedPacket

    var errorDescription: String? {
        switch self {
        case .controlChannelUnavailable:
            "The Sony control channel is not exposed by iOS for this headset."
        case .malformedPacket:
            "The headset sent an invalid response."
        }
    }
}

struct SonyPacketCodec {
    // Sony MDR V1 RFCOMM framing, verified against Sound Connect 13.2.0.
    private static let start: UInt8 = 0x3E
    private static let end: UInt8 = 0x3C
    private static let escape: UInt8 = 0x3D

    func frame(payload: [UInt8], sequence: UInt8, dataType: UInt8 = 0x0C) -> Data {
        let length = UInt32(payload.count)
        // 0x0C is Sony's V1 command packet type.
        var body: [UInt8] = [dataType, sequence,
                             UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
                             UInt8((length >> 8) & 0xff), UInt8(length & 0xff)] + payload
        body.append(body.reduce(0, &+))
        var framed = [Self.start]
        for byte in body {
            if byte == Self.start || byte == Self.end || byte == Self.escape {
                framed.append(Self.escape)
                framed.append(byte & 0xEF)
            } else {
                framed.append(byte)
            }
        }
        framed.append(Self.end)
        return Data(framed)
    }
}

final class SonyFrameParser {
    private var reading = false
    private var escaped = false
    private var body: [UInt8] = []

    func reset() {
        reading = false
        escaped = false
        body.removeAll(keepingCapacity: true)
    }

    func feed(_ data: Data) -> [(type: UInt8, sequence: UInt8, payload: [UInt8])] {
        var packets: [(UInt8, UInt8, [UInt8])] = []
        for byte in data {
            if !reading {
                if byte == 0x3E { reading = true; body.removeAll(); escaped = false }
                continue
            }
            if byte == 0x3C {
                defer { reading = false; escaped = false; body.removeAll() }
                guard body.count >= 7 else { continue }
                let length = (Int(body[2]) << 24) | (Int(body[3]) << 16) | (Int(body[4]) << 8) | Int(body[5])
                guard body.count == 7 + length else { continue }
                let checksum = body.prefix(6 + length).reduce(UInt8(0), &+)
                guard checksum == body[6 + length] else { continue }
                packets.append((body[0], body[1], Array(body[6..<(6 + length)])))
            } else if escaped {
                body.append(byte | 0x10)
                escaped = false
            } else if byte == 0x3D {
                escaped = true
            } else if byte == 0x3E {
                body.removeAll()
            } else {
                body.append(byte)
            }
        }
        return packets
    }
}
