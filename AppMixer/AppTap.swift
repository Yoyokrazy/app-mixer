import AudioToolbox
import Foundation
import Synchronization

/// Intercepts one app's audio and replays it on the output device at a chosen gain.
///
/// A process tap mutes the app at the HAL and exposes its audio as an input stream; a private
/// aggregate device pairs that stream with the real output device, and an IOProc on the aggregate
/// copies tap → output while applying gain. Private taps and aggregates are owned by this process,
/// so the system tears them down (un-muting the app) if App Mixer exits for any reason.
@MainActor
final class AppTap {
    nonisolated static let aggregateNamePrefix = "AppMixer-"

    let processes: [AudioObjectID]
    let outputID: AudioDeviceID
    let outputUID: String

    private let render: TapRenderer
    private var tapID: AudioObjectID
    private var aggregateID: AudioDeviceID
    private var procID: AudioDeviceIOProcID?

    var gain: Float {
        get { render.targetGain }
        set { render.targetGain = newValue }
    }

    init(app: AudioApp, output: OutputDevice, gain: Float) throws {
        processes = app.processes
        outputID = output.id
        outputUID = output.uid

        let description = CATapDescription(stereoMixdownOfProcesses: app.processes)
        description.uuid = UUID()
        description.name = "App Mixer – \(app.name)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true

        var tapID = AudioObjectID.unknown
        try check(AudioHardwareCreateProcessTap(description, &tapID), "tap \(app.name)")

        var aggregateID = AudioDeviceID.unknown
        var procID: AudioDeviceIOProcID?
        func cleanUp() {
            Self.destroy(tapID: tapID, aggregateID: aggregateID, procID: procID)
        }

        do {
            let subDevices = output.id.aggregateSubDeviceUIDs ?? [output.uid]
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "\(Self.aggregateNamePrefix)\(app.id)",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: subDevices[0],
                kAudioAggregateDeviceClockDeviceKey: subDevices[0],
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: subDevices.enumerated().map { index, uid in
                    [kAudioSubDeviceUIDKey: uid, kAudioSubDeviceDriftCompensationKey: index > 0]
                },
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    // Bluetooth output shares the tap's clock domain; compensating there causes periodic crackle.
                    kAudioSubTapDriftCompensationKey: !output.id.isBluetooth,
                ]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create aggregate device")
            guard Self.waitUntilAlive(aggregateID) else {
                throw CoreAudioError(operation: "start aggregate device", status: kAudioHardwareNotRunningError)
            }

            let sampleRate = Float(aggregateID.nominalSampleRate ?? 48_000)
            let channels = output.id.preferredStereoChannels
            let renderer = TapRenderer(
                gain: gain,
                // ~30 ms one-pole ramp so slider moves don't click.
                rampCoefficient: 1 - exp(-1 / (sampleRate * 0.03)),
                left: channels.left,
                right: channels.right
            )
            try check(
                AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { @Sendable _, input, _, output, _ in
                    renderer.render(input: input, output: output)
                },
                "create IO proc"
            )
            Self.useOnlyTapInput(aggregateID: aggregateID, procID: procID)
            try check(AudioDeviceStart(aggregateID, procID), "start audio")

            render = renderer
            self.tapID = tapID
            self.aggregateID = aggregateID
            self.procID = procID
        } catch {
            cleanUp()
            throw error
        }
    }

    func destroy() {
        Self.destroy(tapID: tapID, aggregateID: aggregateID, procID: procID)
        tapID = .unknown
        aggregateID = .unknown
        procID = nil
    }

    /// Order matters: stop IO, then the IOProc (blocks until the callback returns), the aggregate, and the tap.
    private static func destroy(tapID: AudioObjectID, aggregateID: AudioDeviceID, procID: AudioDeviceIOProcID?) {
        if aggregateID.isValid, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
        }
    }

    /// Aggregates are normally alive as soon as they're created; poll briefly just in case.
    /// Deliberately doesn't spin the run loop, which could re-enter Mixer mid-setup.
    private static func waitUntilAlive(_ device: AudioDeviceID, timeout: TimeInterval = 1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !device.isAlive {
            guard Date() < deadline else { return false }
            usleep(10_000)
        }
        return true
    }

    /// If the output device also has inputs (USB headsets, audio interfaces), tell the HAL this IOProc
    /// only reads the tap stream. Otherwise the device's mic gets powered and macOS treats it as mic use.
    private static func useOnlyTapInput(aggregateID: AudioDeviceID, procID: AudioDeviceIOProcID?) {
        guard let procID else { return }
        let inputCount = aggregateID.streamCount(scope: kAudioObjectPropertyScopeInput)
        guard inputCount > 1 else { return }

        // AudioHardwareIOProcStreamUsage: { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
        let headerSize = MemoryLayout<UnsafeMutableRawPointer>.size + MemoryLayout<UInt32>.size
        let totalSize = headerSize + inputCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: totalSize, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
        defer { raw.deallocate() }

        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        raw.storeBytes(of: UInt32(inputCount), toByteOffset: MemoryLayout<UnsafeMutableRawPointer>.size, as: UInt32.self)
        for index in 0..<inputCount {
            let isTapStream: UInt32 = index == inputCount - 1 ? 1 : 0
            raw.storeBytes(of: isTapStream, toByteOffset: headerSize + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(aggregateID, &address, 0, nil, UInt32(totalSize), raw)
    }
}

/// State shared with the real-time IO thread. Everything here is lock- and allocation-free.
final class TapRenderer: Sendable {
    private let target: Atomic<UInt32>
    private let current: Atomic<UInt32>
    private let rampCoefficient: Float
    private let left: Int
    private let right: Int

    init(gain: Float, rampCoefficient: Float, left: Int, right: Int) {
        target = Atomic(gain.bitPattern)
        current = Atomic(gain.bitPattern)
        self.rampCoefficient = rampCoefficient
        self.left = left
        self.right = right
    }

    var targetGain: Float {
        get { Float(bitPattern: target.load(ordering: .relaxed)) }
        set { target.store(newValue.bitPattern, ordering: .relaxed) }
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        // The tap is the aggregate's last input stream (any hardware inputs come first).
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let tap = inputs.last, let source = tap.mData?.assumingMemoryBound(to: Float.self) else { return }
        let sourceChannels = max(1, Int(tap.mNumberChannels))
        var frames = Int(tap.mDataByteSize) / (MemoryLayout<Float>.size * sourceChannels)

        // Locate the preferred stereo pair, whose channel indices span all output streams.
        var leftOut: (samples: UnsafeMutablePointer<Float>, stride: Int)?
        var rightOut: (samples: UnsafeMutablePointer<Float>, stride: Int)?
        var firstChannel = 0
        for buffer in outputs {
            let channels = max(1, Int(buffer.mNumberChannels))
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                frames = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
                if leftOut == nil, (firstChannel..<firstChannel + channels).contains(left) {
                    leftOut = (data + (left - firstChannel), channels)
                }
                if rightOut == nil, (firstChannel..<firstChannel + channels).contains(right) {
                    rightOut = (data + (right - firstChannel), channels)
                }
            }
            firstChannel += channels
        }
        if leftOut == nil, let first = outputs.first, let data = first.mData?.assumingMemoryBound(to: Float.self) {
            let channels = max(1, Int(first.mNumberChannels))
            leftOut = (data, channels)
            rightOut = channels > 1 ? (data + 1, channels) : nil
        }
        guard let leftOut else { return }

        let targetGain = Float(bitPattern: target.load(ordering: .relaxed))
        var gain = Float(bitPattern: current.load(ordering: .relaxed))
        let rightSourceOffset = sourceChannels > 1 ? 1 : 0

        for frame in 0..<frames {
            gain += (targetGain - gain) * rampCoefficient
            let l = source[frame * sourceChannels] * gain
            let r = source[frame * sourceChannels + rightSourceOffset] * gain
            if let rightOut {
                leftOut.samples[frame * leftOut.stride] = l
                rightOut.samples[frame * rightOut.stride] = r
            } else {
                leftOut.samples[frame * leftOut.stride] = (l + r) * 0.5
            }
        }
        if abs(targetGain - gain) < 1e-6 { gain = targetGain }
        current.store(gain.bitPattern, ordering: .relaxed)
    }
}
