import AudioToolbox

/// A live tap as `Mixer` sees it: where it plays, what it captures, and its gain.
@MainActor
protocol ProcessTap: AnyObject {
    var processes: [AudioObjectID] { get }
    var outputID: AudioDeviceID { get }
    var outputUID: String { get }
    var gain: Float { get set }
    func destroy()
}

extension AppTap: ProcessTap {}

/// Every Core Audio side effect `Mixer` relies on, so its decisions can be tested without audio hardware.
@MainActor
protocol AudioSystem {
    func scanApps() -> [AudioApp]
    func outputDevices() -> [OutputDevice]
    func defaultOutputDevice() -> OutputDevice?
    func sampleRate(of device: AudioDeviceID) -> Double?
    /// False once a process object's process has exited.
    func isProcessAlive(_ process: AudioObjectID) -> Bool
    func makeTap(for app: AudioApp, on output: OutputDevice, gain: Float) throws -> any ProcessTap
    /// Calls `handler` when the property changes, for as long as the returned token is retained.
    func listen(to object: AudioObjectID, _ selector: AudioObjectPropertySelector, handler: @escaping @MainActor () -> Void) -> AnyObject?
}

struct CoreAudioSystem: AudioSystem {
    func scanApps() -> [AudioApp] {
        AudioAppScanner.scan()
    }

    func outputDevices() -> [OutputDevice] {
        OutputDevice.all
    }

    func defaultOutputDevice() -> OutputDevice? {
        OutputDevice(AudioObjectID.defaultOutputDevice)
    }

    func sampleRate(of device: AudioDeviceID) -> Double? {
        device.nominalSampleRate
    }

    func isProcessAlive(_ process: AudioObjectID) -> Bool {
        process.processPID != nil
    }

    func makeTap(for app: AudioApp, on output: OutputDevice, gain: Float) throws -> any ProcessTap {
        try AppTap(app: app, output: output, gain: gain)
    }

    func listen(to object: AudioObjectID, _ selector: AudioObjectPropertySelector, handler: @escaping @MainActor () -> Void) -> AnyObject? {
        PropertyListener(object, selector, handler: handler)
    }
}
