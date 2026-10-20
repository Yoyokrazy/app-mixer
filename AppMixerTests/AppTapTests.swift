import AudioToolbox
import Testing

/// The parts of `AppTap` that don't need a real tap. Creating one is covered by the opt-in integration tests.
@Suite("AppTap")
struct AppTapTests {
    // MARK: - Aggregate description

    @Test func describesAPrivateStackedAggregateForOneDevice() throws {
        let tapUUID = UUID()
        let description = AppTap.aggregateDescription(appID: "com.apple.Music", tapUUID: tapUUID, subDevices: ["speakers"], compensateTapDrift: true)

        #expect(description[kAudioAggregateDeviceNameKey] as? String == "AppMixer-com.apple.Music")
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == "speakers")
        #expect(description[kAudioAggregateDeviceClockDeviceKey] as? String == "speakers")
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(description[kAudioAggregateDeviceIsStackedKey] as? Bool == true)
        #expect(description[kAudioAggregateDeviceTapAutoStartKey] as? Bool == true)
        let uid = try #require(description[kAudioAggregateDeviceUIDKey] as? String)
        #expect(UUID(uuidString: uid) != nil)

        let subDevices = try #require(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(subDevices.count == 1)
        #expect(subDevices[0][kAudioSubDeviceUIDKey] as? String == "speakers")
        #expect(subDevices[0][kAudioSubDeviceDriftCompensationKey] as? Bool == false)

        let taps = try #require(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        #expect(taps.count == 1)
        #expect(taps[0][kAudioSubTapUIDKey] as? String == tapUUID.uuidString)
        #expect(taps[0][kAudioSubTapDriftCompensationKey] as? Bool == true)
    }

    @Test func multiOutputDeviceIsClockedByItsFirstSubDevice() throws {
        let description = AppTap.aggregateDescription(appID: "x", tapUUID: UUID(), subDevices: ["main", "second", "third"], compensateTapDrift: true)

        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == "main")
        #expect(description[kAudioAggregateDeviceClockDeviceKey] as? String == "main")
        let subDevices = try #require(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(subDevices.map { $0[kAudioSubDeviceUIDKey] as? String } == ["main", "second", "third"])
        #expect(subDevices.map { $0[kAudioSubDeviceDriftCompensationKey] as? Bool } == [false, true, true])
    }

    @Test func bluetoothSkipsTapDriftCompensation() throws {
        let description = AppTap.aggregateDescription(appID: "x", tapUUID: UUID(), subDevices: ["airpods"], compensateTapDrift: false)
        let taps = try #require(description[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        #expect(taps[0][kAudioSubTapDriftCompensationKey] as? Bool == false)
    }

    @Test func everyAggregateGetsAFreshUID() {
        let first = AppTap.aggregateDescription(appID: "x", tapUUID: UUID(), subDevices: ["a"], compensateTapDrift: true)
        let second = AppTap.aggregateDescription(appID: "x", tapUUID: UUID(), subDevices: ["a"], compensateTapDrift: true)
        #expect(first[kAudioAggregateDeviceUIDKey] as? String != second[kAudioAggregateDeviceUIDKey] as? String)
    }

    @Test func aggregateNamesAreRecognizableAsOurs() {
        #expect(AppTap.aggregateNamePrefix == "AppMixer-")
    }

    // MARK: - IOProc stream usage

    @Test func streamUsageLayoutMatchesTheSDK() {
        typealias Usage = AudioHardwareIOProcStreamUsage
        #expect(MemoryLayout<Usage>.offset(of: \.mNumberStreams) == MemoryLayout<UnsafeMutableRawPointer>.size)
        #expect(MemoryLayout<Usage>.offset(of: \.mStreamIsOn) == MemoryLayout<UnsafeMutableRawPointer>.size + 4)
        #expect(AppTap.streamUsageSize(streamCount: 1) == MemoryLayout<Usage>.size)
        #expect(AppTap.streamUsageSize(streamCount: 3) == MemoryLayout<Usage>.size + 2 * 4)
    }

    @Test(arguments: [2, 3, 5])
    func streamUsageTurnsOnOnlyTheTapStream(streamCount: Int) throws {
        let size = AppTap.streamUsageSize(streamCount: streamCount)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        raw.initializeMemory(as: UInt8.self, repeating: 0xAB, count: size)
        let procID = try #require(UnsafeMutableRawPointer(bitPattern: 0xFEED_F00D))

        AppTap.writeTapOnlyStreamUsage(into: raw, procID: procID, streamCount: streamCount)

        let usage = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self).pointee
        #expect(usage.mIOProc == procID)
        #expect(Int(usage.mNumberStreams) == streamCount)
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let flags = (0..<streamCount).map { raw.load(fromByteOffset: flagsOffset + $0 * 4, as: UInt32.self) }
        #expect(flags == Array(repeating: 0, count: streamCount - 1) + [1])
    }

    // MARK: - Waiting for the aggregate

    @Test @MainActor func waitingForAMissingDeviceTimesOut() {
        let start = Date()
        #expect(!AppTap.waitUntilAlive(.unknown, timeout: 0.05))
        #expect(Date().timeIntervalSince(start) >= 0.05)
    }

    @Test @MainActor func aliveDeviceIsReadyImmediately() {
        let device = AudioObjectID.defaultOutputDevice
        guard device.isValid else { return } // no output device on this machine (e.g. CI)
        #expect(AppTap.waitUntilAlive(device, timeout: 0))
    }
}
