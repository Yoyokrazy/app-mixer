import AudioToolbox
import Testing

/// Read-only queries against the real HAL. They hold with or without audio devices (CI runners may have
/// none) and never create taps, aggregates, or anything else with side effects.
@Suite("Core Audio helpers")
struct CoreAudioHelperTests {
    @Test func unknownObjectReadsFail() {
        let unknown = AudioObjectID.unknown
        #expect(!unknown.isValid)
        #expect(unknown.read(kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) == nil)
        #expect(unknown.readArray(kAudioDevicePropertyStreams, initial: AudioStreamID(0)).isEmpty)
        #expect(unknown.readString(kAudioObjectPropertyName) == nil)
        #expect(unknown.processPID == nil)
        #expect(!unknown.isRunningOutput)
        #expect(unknown.deviceUID == nil)
        #expect(!unknown.isAlive)
        #expect(unknown.nominalSampleRate == nil)
        #expect(!unknown.isBluetooth)
        #expect(unknown.aggregateSubDeviceUIDs == nil)
        #expect(unknown.streamCount(scope: kAudioObjectPropertyScopeOutput) == 0)
    }

    @Test func unreadableStereoPairFallsBackToTheFirstTwoChannels() {
        let channels = AudioObjectID.unknown.preferredStereoChannels
        #expect(channels.left == 0)
        #expect(channels.right == 1)
    }

    @Test func systemObjectAnswersQueries() {
        #expect(AudioObjectID.system.isValid)
        let devices = AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, initial: AudioDeviceID.unknown)
        #expect(devices.allSatisfy { $0.isValid })
        #expect(AudioObjectID.processList.allSatisfy { $0.isValid })
        let defaultDevice = AudioObjectID.defaultOutputDevice
        if defaultDevice.isValid {
            #expect(devices.contains(defaultDevice))
        }
    }

    @Test func listedOutputDevicesAreUsable() {
        for device in OutputDevice.all {
            #expect(!device.name.hasPrefix(AppTap.aggregateNamePrefix))
            #expect(!device.uid.isEmpty)
            #expect(device.id.streamCount(scope: kAudioObjectPropertyScopeOutput) > 0)
            #expect(device.id.isAlive)
            #expect(OutputDevice(device.id) == device)
            let channels = device.id.preferredStereoChannels
            #expect(channels.left >= 0 && channels.right >= 0)
            if let rate = device.id.nominalSampleRate {
                #expect(rate > 0)
            }
            if let subDevices = device.id.aggregateSubDeviceUIDs {
                #expect(!subDevices.isEmpty)
            }
            if device.id.isBluetooth {
                #expect(device.symbolName == "headphones")
            }
        }
    }

    @Test func processObjectsHavePIDs() {
        for process in AudioObjectID.processList {
            if let pid = process.processPID {
                #expect(pid > 0)
            }
            _ = process.isRunningOutput
        }
    }
}

@Suite("PropertyListener")
@MainActor
struct PropertyListenerTests {
    @Test func registersOnTheSystemObject() {
        let listener = PropertyListener(.system, kAudioHardwarePropertyDevices) {}
        #expect(listener != nil)
    }

    @Test func refusesUnknownObjects() {
        #expect(PropertyListener(.unknown, kAudioHardwarePropertyDevices) {} == nil)
    }
}

@Suite("CoreAudioSystem")
@MainActor
struct CoreAudioSystemTests {
    @Test func forwardsToTheHAL() {
        let system = CoreAudioSystem()
        #expect(system.outputDevices() == OutputDevice.all)
        #expect(system.defaultOutputDevice() == OutputDevice(AudioObjectID.defaultOutputDevice))
        #expect(system.sampleRate(of: .unknown) == nil)
        #expect(!system.isProcessAlive(.unknown))
        #expect(system.listen(to: .system, kAudioHardwarePropertyDevices) {} != nil)
        #expect(system.listen(to: .unknown, kAudioHardwarePropertyDevices) {} == nil)
        if let device = system.defaultOutputDevice() {
            #expect(system.sampleRate(of: device.id) == device.id.nominalSampleRate)
        }
    }

    @Test func scanFindsWellFormedApps() {
        let apps = CoreAudioSystem().scanApps()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        #expect(Set(apps.map(\.id)).count == apps.count)
        for (previous, next) in zip(apps, apps.dropFirst()) {
            #expect(previous.name.localizedCaseInsensitiveCompare(next.name) != .orderedDescending)
        }
        for app in apps {
            #expect(!app.processes.isEmpty)
            #expect(app.processes == app.processes.sorted())
            #expect(!app.processes.contains { $0.processPID == ownPID })
        }
    }

    /// Never taps: permission is denied and no levels are saved, so this only exercises discovery.
    @Test func mixerRunsAgainstTheRealSystem() {
        let tcc = FakeTCC()
        tcc.status = .denied
        let mixer = Mixer(system: CoreAudioSystem(), defaults: TestDefaults(), permission: CapturePermission(access: tcc.access))

        mixer.start()

        #expect(tcc.requestCount == 0)
        #expect(mixer.outputDevices == OutputDevice.all)
        #expect(mixer.defaultOutput == CoreAudioSystem().defaultOutputDevice())
        #expect(!mixer.hasChanges)
        #expect(mixer.lastError == nil)
        mixer.refresh()
        mixer.shutdown()
    }
}
