# XMGo — Sony MFi interoperability request

## Project

- App name: XMGo
- iOS bundle identifier: `com.xmgo.fares.app`
- Target accessory: Sony WH-1000XM4
- Intended distribution: personal development build initially; possible wider distribution only with Sony and Apple approval
- Transport requested: the MFi/iAP Bluetooth Classic protocol used by Sony Sound Connect for headset control

## Requested information and authorization

Please provide:

1. The reverse-DNS External Accessory protocol string advertised by the WH-1000XM4 for its control channel.
2. The corresponding protocol documentation or an SDK covering status, battery, ANC/ambient sound, equalizer, Clear Bass, Speak-to-Chat and wearing detection.
3. Authorization of the iOS application identifier `com.xmgo.fares.app` for interoperability with the relevant MFi accessory Product Plan ID.
4. Confirmation that Sony has submitted, or will submit, this third-party application authorization to Apple's MFi Program.
5. Any required Sony partner agreement, compatibility validation or branding requirements.

## Technical approach

XMGo is a native Swift/SwiftUI iOS 26 application. It uses Apple's public `ExternalAccessory` framework and `EASession`. It does not intend to alter headset firmware or bypass accessory authentication. The Sony binary command codec and transport are isolated so Sony-supplied documentation can replace community-derived protocol details.

## User problem

The project provides a lightweight and accessible alternative control surface for owners who experience slow or unreliable operation in the official application. Audio pairing remains managed entirely by iOS.
