import AudioToolbox
import Foundation

struct CoreAudioError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? { "Couldn't \(operation) (OSStatus \(status))" }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(operation: operation, status: status) }
}

// MARK: - Property access

extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let system = AudioObjectID(kAudioObjectSystemObject)

    var isValid: Bool { self != .unknown }

    func read<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> T? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        return AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    func readArray<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [T](repeating: initial, count: Int(size) / MemoryLayout<T>.stride)
        let status = items.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(items.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// CF-returning selectors hand back a +1 reference, so the value is taken as retained.
    func readString(_ selector: AudioObjectPropertySelector) -> String? {
        guard let value = read(selector, initial: Unmanaged<CFString>?.none) ?? nil else { return nil }
        let string = value.takeRetainedValue() as String
        return string.isEmpty ? nil : string
    }
}

// MARK: - System

extension AudioObjectID {
    static var processList: [AudioObjectID] {
        system.readArray(kAudioHardwarePropertyProcessObjectList, initial: AudioObjectID.unknown)
    }

    static var defaultOutputDevice: AudioDeviceID {
        system.read(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID.unknown) ?? .unknown
    }
}

// MARK: - Process objects

extension AudioObjectID {
    var processPID: pid_t? { read(kAudioProcessPropertyPID, initial: pid_t(-1)) }
    var isRunningOutput: Bool { (read(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0 }
}

// MARK: - Devices

extension AudioDeviceID {
    var deviceUID: String? { readString(kAudioDevicePropertyDeviceUID) }
    var isAlive: Bool { (read(kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0)) ?? 0) != 0 }
    var nominalSampleRate: Double? { read(kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) }

    var isBluetooth: Bool {
        let transport = read(kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    /// Hardware sub-devices of an aggregate (e.g. a Multi-Output Device), or nil for a regular device.
    /// Aggregates can't be nested, so ours has to wrap these directly.
    var aggregateSubDeviceUIDs: [String]? {
        let transport = read(kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
        guard transport == kAudioDeviceTransportTypeAggregate,
              let list = read(kAudioAggregateDevicePropertyFullSubDeviceList, initial: Unmanaged<CFArray>?.none) ?? nil,
              let uids = list.takeRetainedValue() as? [String], !uids.isEmpty
        else { return nil }
        return uids
    }

    /// Zero-based indices of the device's preferred stereo pair.
    var preferredStereoChannels: (left: Int, right: Int) {
        let pair = read(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioObjectPropertyScopeOutput, initial: (UInt32(1), UInt32(2)))
        guard let pair, pair.0 > 0, pair.1 > 0 else { return (0, 1) }
        return (Int(pair.0) - 1, Int(pair.1) - 1)
    }

    func streamCount(scope: AudioObjectPropertyScope) -> Int {
        readArray(kAudioDevicePropertyStreams, scope: scope, initial: AudioStreamID(0)).count
    }
}

/// A device that can play audio, as offered in Control Center's output list.
struct OutputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32

    init?(_ id: AudioDeviceID) {
        guard id.isValid, let uid = id.deviceUID else { return nil }
        self.id = id
        self.uid = uid
        name = id.readString(kAudioObjectPropertyName) ?? uid
        transport = id.read(kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
    }

    init(id: AudioDeviceID, uid: String, name: String, transport: UInt32) {
        self.id = id
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    var symbolName: String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: "laptopcomputer"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "tv"
        case kAudioDeviceTransportTypeVirtual: "waveform"
        case kAudioDeviceTransportTypeAggregate: "square.stack.3d.up"
        default: "hifispeaker"
        }
    }

    /// Output devices the user could pick, in system order. Skips hidden devices, ones macOS won't use as
    /// a default output (loopback drivers like Teams Audio), and App Mixer's own aggregate devices.
    static var all: [OutputDevice] {
        AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, initial: AudioDeviceID.unknown).compactMap { id in
            guard id.streamCount(scope: kAudioObjectPropertyScopeOutput) > 0,
                  (id.read(kAudioDevicePropertyIsHidden, initial: UInt32(0)) ?? 0) == 0,
                  (id.read(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0)) ?? 0) != 0,
                  let device = OutputDevice(id),
                  !device.name.hasPrefix(AppTap.aggregateNamePrefix)
            else { return nil }
            return device
        }
    }
}

// MARK: - Listening

/// Registers a HAL property listener that fires on the main queue; removed on deinit.
final class PropertyListener: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, handler: @escaping @MainActor () -> Void) {
        self.object = object
        address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        block = { _, _ in MainActor.assumeIsolated { handler() } }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
    }

    deinit {
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
    }
}
