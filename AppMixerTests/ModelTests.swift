import AppKit
import AudioToolbox
import Testing

@Suite("AppLevel")
struct AppLevelTests {
    @Test func defaultsToFullVolumeUnmuted() {
        let level = AppLevel()
        #expect(level.volume == 1)
        #expect(!level.muted)
        #expect(level.isUnity)
        #expect(level.gain == 1)
    }

    @Test(arguments: [
        (volume: 1.0, muted: false, isUnity: true),
        (volume: 1.2, muted: false, isUnity: true),
        (volume: 0.99, muted: false, isUnity: false),
        (volume: 0.0, muted: false, isUnity: false),
        (volume: 1.0, muted: true, isUnity: false),
    ])
    func isUnityOnlyAtFullVolumeUnmuted(volume: Double, muted: Bool, isUnity: Bool) {
        #expect(AppLevel(volume: volume, muted: muted).isUnity == isUnity)
    }

    @Test(arguments: [(0.0, Float(0)), (0.5, 0.25), (0.8, 0.64), (1.0, 1)])
    func gainFollowsASquareLawTaper(volume: Double, gain: Float) {
        #expect(abs(AppLevel(volume: volume).gain - gain) < 1e-6)
    }

    @Test func halfVolumeIsAboutMinusTwelveDecibels() {
        let decibels = 20 * log10(AppLevel(volume: 0.5).gain)
        #expect(abs(decibels - -12.04) < 0.01)
    }

    @Test func mutedGainIsSilentAtAnyVolume() {
        #expect(AppLevel(volume: 0.7, muted: true).gain == 0)
        #expect(AppLevel(volume: 1, muted: true).gain == 0)
    }

    @Test func roundTripsThroughJSON() throws {
        let level = AppLevel(volume: 0.35, muted: true)
        let decoded = try JSONDecoder().decode(AppLevel.self, from: JSONEncoder().encode(level))
        #expect(decoded == level)
    }

    @Test func decodesTheSavedFormat() throws {
        let json = Data(#"{"volume":0.5,"muted":false}"#.utf8)
        #expect(try JSONDecoder().decode(AppLevel.self, from: json) == AppLevel(volume: 0.5, muted: false))
    }
}

@Suite("Route")
struct RouteTests {
    @Test func roundTripsThroughJSON() throws {
        let route = Route(uid: "BuiltInSpeakerDevice", name: "MacBook Pro Speakers")
        let decoded = try JSONDecoder().decode(Route.self, from: JSONEncoder().encode(route))
        #expect(decoded == route)
    }

    @Test func decodesTheSavedFormat() throws {
        let json = Data(#"{"uid":"airpods","name":"AirPods Pro"}"#.utf8)
        #expect(try JSONDecoder().decode(Route.self, from: json) == Route(uid: "airpods", name: "AirPods Pro"))
    }

    @Test func equalityComparesUIDAndName() {
        #expect(Route(uid: "a", name: "A") == Route(uid: "a", name: "A"))
        #expect(Route(uid: "a", name: "A") != Route(uid: "b", name: "A"))
        #expect(Route(uid: "a", name: "A") != Route(uid: "a", name: "Renamed"))
    }
}

@Suite("OutputDevice")
struct OutputDeviceTests {
    @Test(arguments: [
        (kAudioDeviceTransportTypeBuiltIn, "laptopcomputer"),
        (kAudioDeviceTransportTypeBluetooth, "headphones"),
        (kAudioDeviceTransportTypeBluetoothLE, "headphones"),
        (kAudioDeviceTransportTypeAirPlay, "airplayaudio"),
        (kAudioDeviceTransportTypeHDMI, "tv"),
        (kAudioDeviceTransportTypeDisplayPort, "tv"),
        (kAudioDeviceTransportTypeVirtual, "waveform"),
        (kAudioDeviceTransportTypeAggregate, "square.stack.3d.up"),
        (kAudioDeviceTransportTypeUSB, "hifispeaker"),
        (kAudioDeviceTransportTypeThunderbolt, "hifispeaker"),
        (UInt32(0), "hifispeaker"),
    ])
    func symbolMatchesTransport(transport: UInt32, symbol: String) {
        let device = OutputDevice(id: 1, uid: "uid", name: "Device", transport: transport)
        #expect(device.symbolName == symbol)
    }

    @Test func symbolsExistInSFSymbols() {
        let transports = [
            kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeAirPlay,
            kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate, 0,
        ]
        for transport in transports {
            let symbol = OutputDevice(id: 1, uid: "uid", name: "Device", transport: transport).symbolName
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }

    @Test func memberwiseInitKeepsEveryField() {
        let device = OutputDevice(id: 42, uid: "usb-dac", name: "USB DAC", transport: kAudioDeviceTransportTypeUSB)
        #expect(device.id == 42)
        #expect(device.uid == "usb-dac")
        #expect(device.name == "USB DAC")
        #expect(device.transport == kAudioDeviceTransportTypeUSB)
    }

    @Test func equalityComparesEveryField() {
        let device = OutputDevice(id: 1, uid: "a", name: "A", transport: 0)
        #expect(device == OutputDevice(id: 1, uid: "a", name: "A", transport: 0))
        #expect(device != OutputDevice(id: 2, uid: "a", name: "A", transport: 0))
        #expect(device != OutputDevice(id: 1, uid: "b", name: "A", transport: 0))
        #expect(device != OutputDevice(id: 1, uid: "a", name: "B", transport: 0))
        #expect(device != OutputDevice(id: 1, uid: "a", name: "A", transport: 1))
    }

    @Test func invalidObjectIsNotADevice() {
        #expect(OutputDevice(AudioObjectID.unknown) == nil)
    }
}

@Suite("AudioApp")
@MainActor
struct AudioAppTests {
    @Test func equalityIgnoresTheIcon() {
        let a = AudioApp(id: "x", name: "X", icon: NSImage(), processes: [1], isPlaying: false, isRegularApp: true)
        let b = AudioApp(id: "x", name: "X", icon: NSImage(size: NSSize(width: 4, height: 4)), processes: [1], isPlaying: false, isRegularApp: true)
        #expect(a == b)
    }

    @Test func equalityComparesEverythingElse() {
        let base = AudioApp(id: "x", name: "X", icon: NSImage(), processes: [1], isPlaying: false, isRegularApp: true)
        var other = base
        other.processes = [1, 2]
        #expect(base != other)
        other = base
        other.isPlaying = true
        #expect(base != other)
        #expect(base != AudioApp(id: "y", name: "X", icon: NSImage(), processes: [1], isPlaying: false, isRegularApp: true))
        #expect(base != AudioApp(id: "x", name: "Y", icon: NSImage(), processes: [1], isPlaying: false, isRegularApp: true))
        #expect(base != AudioApp(id: "x", name: "X", icon: NSImage(), processes: [1], isPlaying: false, isRegularApp: false))
    }
}

@Suite("CoreAudioError")
struct CoreAudioErrorTests {
    @Test func describesTheOperationAndStatus() {
        let error = CoreAudioError(operation: "create aggregate device", status: -50)
        #expect(error.errorDescription == "Couldn't create aggregate device (OSStatus -50)")
        #expect(error.localizedDescription == "Couldn't create aggregate device (OSStatus -50)")
    }

    @Test func checkPassesNoErrThrough() throws {
        try check(noErr, "anything")
    }

    @Test func checkThrowsOnFailure() {
        let error = #expect(throws: CoreAudioError.self) {
            try check(kAudioHardwareBadObjectError, "tap Music")
        }
        #expect(error?.operation == "tap Music")
        #expect(error?.status == kAudioHardwareBadObjectError)
    }
}

@Suite("RowStyle")
struct RowStyleTests {
    @Test func compactComesFirst() {
        #expect(RowStyle.allCases == [.compact, .standard])
    }

    @Test func titlesAreUserFacing() {
        #expect(RowStyle.compact.title == "Compact")
        #expect(RowStyle.standard.title == "Standard")
    }

    @Test func storedAsItsRawValue() {
        #expect(RowStyle.storageKey == "rowStyle")
        #expect(RowStyle(rawValue: "standard") == .standard)
        #expect(RowStyle(rawValue: "compact")?.id == .compact)
        #expect(RowStyle(rawValue: "huge") == nil)
    }
}
