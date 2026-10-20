import AppKit
import AudioToolbox
import Testing

/// Opt-in tests against real Core Audio: they create a process tap, a private aggregate device, and an
/// IOProc. Run with `TEST_RUNNER_APP_MIXER_INTEGRATION=1 make test` on a Mac with an output device.
///
/// The tap only covers this test process (which plays nothing), so no other app's audio is affected.
/// Tests are skipped unless System Audio Recording is already granted to whatever launched them (Terminal,
/// Xcode, ...), so they never trigger a permission prompt.
@Suite(
    "Integration",
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["APP_MIXER_INTEGRATION"] == "1", "set TEST_RUNNER_APP_MIXER_INTEGRATION=1 to run"),
    .enabled("needs an output device") { AudioObjectID.defaultOutputDevice.isValid },
    .enabled("needs System Audio Recording permission") { await MainActor.run { CapturePermission.tcc.preflight() == .authorized } }
)
@MainActor
struct IntegrationTests {
    /// This process's Core Audio process object, if the HAL has registered it.
    static func ownProcessObject() -> AudioObjectID {
        var pid = getpid()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var object = AudioObjectID.unknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr ? object : .unknown
    }

    static func deviceNames() -> [String] {
        AudioObjectID.system.readArray(kAudioHardwarePropertyDevices, initial: AudioDeviceID.unknown)
            .compactMap { $0.readString(kAudioObjectPropertyName) }
    }

    @Test func tapLifecycleOnTheDefaultOutput() async throws {
        let output = try #require(CoreAudioSystem().defaultOutputDevice())
        let ownProcess = Self.ownProcessObject()
        let app = AudioApp(
            id: "com.yoyokrazy.AppMixerTests.integration",
            name: "App Mixer Tests",
            icon: NSImage(),
            processes: ownProcess.isValid ? [ownProcess] : [],
            isPlaying: false,
            isRegularApp: false
        )
        let aggregateName = AppTap.aggregateNamePrefix + app.id
        let devicesChanged = Flag()
        let listener = PropertyListener(.system, kAudioHardwarePropertyDevices) { devicesChanged.set() }
        #expect(listener != nil)

        let tap = try CoreAudioSystem().makeTap(for: app, on: output, gain: 0.5)

        #expect(tap.outputUID == output.uid)
        #expect(tap.outputID == output.id)
        #expect(tap.processes == app.processes)
        #expect(tap.gain == 0.5)
        tap.gain = 0.25
        #expect(tap.gain == 0.25)

        // The private aggregate is visible to this process but never offered as an output.
        #expect(Self.deviceNames().contains(aggregateName))
        #expect(!OutputDevice.all.contains { $0.name == aggregateName })
        #expect(await eventually { devicesChanged.isSet })

        tap.destroy()
        #expect(await eventually { !Self.deviceNames().contains(aggregateName) })
        tap.destroy() // a second teardown is harmless
    }
}
