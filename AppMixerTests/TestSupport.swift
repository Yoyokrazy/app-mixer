import AppKit
import AudioToolbox
import Synchronization
import Testing

// MARK: - Isolated defaults

/// In-memory defaults: nothing reaches cfprefsd or disk, so tests can't touch `UserDefaults.standard`,
/// App Mixer's own `com.yoyokrazy.AppMixer` domain (the real app may be running), or leave files behind.
final class TestDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Any] = [:]

    init() {
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { storage[defaultName] }
    }

    override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { storage[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        set(nil, forKey: defaultName)
    }
}

// MARK: - Fake Core Audio

@MainActor
final class FakeTap: ProcessTap {
    let appID: String
    let processes: [AudioObjectID]
    let outputID: AudioDeviceID
    let outputUID: String
    var gain: Float
    private(set) var destroyCount = 0
    private let log: (String) -> Void

    var isDestroyed: Bool { destroyCount > 0 }

    init(app: AudioApp, output: OutputDevice, gain: Float, log: @escaping (String) -> Void) {
        appID = app.id
        processes = app.processes
        outputID = output.id
        outputUID = output.uid
        self.gain = gain
        self.log = log
    }

    func destroy() {
        destroyCount += 1
        log("destroy \(appID)@\(outputUID)")
    }
}

final class ListenerToken {}

/// Stands in for the HAL: apps, devices, and listeners are plain values the test controls.
@MainActor
final class FakeAudioSystem: AudioSystem {
    private struct Listener {
        let object: AudioObjectID
        let selector: AudioObjectPropertySelector
        let handler: @MainActor () -> Void
        weak var token: ListenerToken?
    }

    var apps: [AudioApp] = []
    var devices: [OutputDevice] = []
    var defaultDevice: OutputDevice?
    var sampleRates: [AudioDeviceID: Double] = [:]
    var deadProcesses: Set<AudioObjectID> = []
    /// How many upcoming `makeTap` calls throw.
    var tapFailures = 0
    var listenersFail = false

    private(set) var scanCount = 0
    private(set) var taps: [FakeTap] = []
    /// Tap creations and teardowns in order, e.g. "create com.apple.Music@speakers".
    private(set) var events: [String] = []
    private var listeners: [Listener] = []

    var liveTaps: [FakeTap] { taps.filter { !$0.isDestroyed } }

    func liveTap(for appID: String) -> FakeTap? {
        liveTaps.last { $0.appID == appID }
    }

    /// Listeners the mixer still retains for this object and selector.
    func listenerCount(on object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int {
        listeners.filter { $0.token != nil && $0.object == object && $0.selector == selector }.count
    }

    /// Every listener ever registered for this object and selector, retained or not.
    func registrationCount(on object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int {
        listeners.filter { $0.object == object && $0.selector == selector }.count
    }

    /// Simulates a HAL property-change notification.
    func notify(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        let matching = listeners.filter { $0.token != nil && $0.object == object && $0.selector == selector }
        for listener in matching { listener.handler() }
    }

    func scanApps() -> [AudioApp] {
        scanCount += 1
        return apps
    }

    func outputDevices() -> [OutputDevice] { devices }

    func defaultOutputDevice() -> OutputDevice? { defaultDevice }

    func sampleRate(of device: AudioDeviceID) -> Double? { sampleRates[device] }

    func isProcessAlive(_ process: AudioObjectID) -> Bool { !deadProcesses.contains(process) }

    func makeTap(for app: AudioApp, on output: OutputDevice, gain: Float) throws -> any ProcessTap {
        if tapFailures > 0 {
            tapFailures -= 1
            events.append("fail \(app.id)@\(output.uid)")
            throw CoreAudioError(operation: "tap \(app.name)", status: -1)
        }
        let tap = FakeTap(app: app, output: output, gain: gain) { [weak self] in self?.events.append($0) }
        taps.append(tap)
        events.append("create \(app.id)@\(output.uid)")
        return tap
    }

    func listen(to object: AudioObjectID, _ selector: AudioObjectPropertySelector, handler: @escaping @MainActor () -> Void) -> AnyObject? {
        guard !listenersFail else { return nil }
        let token = ListenerToken()
        listeners.append(Listener(object: object, selector: selector, handler: handler, token: token))
        return token
    }
}

/// Fake TCC: a settable preflight answer, and requests that complete when the test says so.
@MainActor
final class FakeTCC {
    var status: CapturePermission.Status = .authorized
    private(set) var requestCount = 0
    private(set) var completion: (@Sendable (Bool) -> Void)?

    var access: CapturePermission.Access {
        CapturePermission.Access(
            preflight: { self.status },
            request: { completion in
                self.requestCount += 1
                self.completion = completion
            }
        )
    }
}

// MARK: - Time

/// Replaces `Task.sleep`: records each requested delay and suspends until the test fires it.
final class ManualDelay: Sendable {
    private struct Waiter {
        let id: Int
        let duration: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var nextID = 0
        var waiters: [Waiter] = []
        var cancelled: Set<Int> = []
        var history: [Duration] = []
    }

    private let state = Mutex(State())

    /// Delays currently waiting to be fired.
    var pending: [Duration] { state.withLock { $0.waiters.map(\.duration) } }
    /// Every delay ever requested, in order.
    var history: [Duration] { state.withLock { $0.history } }

    func wait(_ duration: Duration) async throws {
        let id = state.withLock { state in
            defer { state.nextID += 1 }
            state.history.append(duration)
            return state.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { state in
                    guard !state.cancelled.contains(id) else { return true }
                    state.waiters.append(Waiter(id: id, duration: duration, continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                if let index = state.waiters.firstIndex(where: { $0.id == id }) {
                    return state.waiters.remove(at: index)
                }
                state.cancelled.insert(id)
                return nil
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Lets every pending delay finish.
    func fireAll() {
        let waiters = state.withLock { state in
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.continuation.resume() }
    }
}

/// Polls until `condition` holds, letting main-actor tasks run in between.
@MainActor
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

/// Gives already-scheduled tasks a chance to run, for asserting that something did *not* happen.
@MainActor
func settle() async {
    for _ in 0..<5 {
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
}

/// A one-way flag that `@Sendable` callbacks (like observation's `onChange`) can set.
final class Flag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

// MARK: - Fixtures

/// Named so it can't clash with the app's DEBUG preview fixtures, which are compiled into this target too.
enum TestFixtures {
    static let speakers = OutputDevice(id: 10, uid: "speakers", name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
    static let airPods = OutputDevice(id: 20, uid: "airpods", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
    static let display = OutputDevice(id: 30, uid: "display", name: "Studio Display", transport: kAudioDeviceTransportTypeDisplayPort)

    static let musicID = "com.apple.Music"
    static let chimeID = "com.example.Chime"

    @MainActor
    static func app(
        _ id: String,
        name: String? = nil,
        processes: [AudioObjectID],
        isPlaying: Bool = false,
        isRegularApp: Bool = true
    ) -> AudioApp {
        AudioApp(
            id: id,
            name: name ?? id.components(separatedBy: ".").last!,
            icon: NSImage(),
            processes: processes,
            isPlaying: isPlaying,
            isRegularApp: isRegularApp
        )
    }

    /// A Dock app with two audio processes.
    @MainActor static var music: AudioApp { app(musicID, processes: [101, 102]) }
    /// A silent menu bar agent.
    @MainActor static var chime: AudioApp { app(chimeID, processes: [201], isRegularApp: false) }
}

// MARK: - Audio buffers

/// An `AudioBufferList` whose buffers own interleaved Float storage, for driving `TapRenderer` directly.
final class TestBufferList {
    struct Stream {
        var channels: Int
        var frames: Int
        var hasData = true
        /// Value every sample starts at, so tests can tell untouched samples from written ones.
        var fill: Float = 0
        /// Extra samples allocated past `mDataByteSize` to catch overruns.
        var guardSamples = 0
    }

    static let guardValue: Float = -12345

    let streams: [Stream]
    let list: UnsafeMutableAudioBufferListPointer
    private let storage: [UnsafeMutablePointer<Float>?]

    init(_ streams: [Stream]) {
        self.streams = streams
        list = AudioBufferList.allocate(maximumBuffers: max(1, streams.count))
        list.count = streams.count
        storage = streams.map { stream in
            guard stream.hasData else { return nil }
            let count = max(1, stream.channels) * stream.frames
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count + stream.guardSamples)
            pointer.initialize(repeating: stream.fill, count: count)
            (pointer + count).initialize(repeating: Self.guardValue, count: stream.guardSamples)
            return pointer
        }
        for (index, stream) in streams.enumerated() {
            let byteSize = max(1, stream.channels) * stream.frames * MemoryLayout<Float>.size
            list[index] = AudioBuffer(mNumberChannels: UInt32(stream.channels), mDataByteSize: UInt32(byteSize), mData: storage[index])
        }
    }

    convenience init(channels: Int, frames: Int, fill: Float = 0) {
        self.init([Stream(channels: channels, frames: frames, fill: fill)])
    }

    deinit {
        for pointer in storage { pointer?.deallocate() }
        free(list.unsafeMutablePointer)
    }

    private func sampleCount(_ stream: Int) -> Int {
        max(1, streams[stream].channels) * streams[stream].frames
    }

    /// Interleaved samples of one stream.
    func samples(stream: Int = 0) -> [Float] {
        guard let pointer = storage[stream] else { return [] }
        return Array(UnsafeBufferPointer(start: pointer, count: sampleCount(stream)))
    }

    func setSamples(_ samples: [Float], stream: Int = 0) {
        precondition(samples.count == sampleCount(stream))
        storage[stream]!.update(from: samples, count: samples.count)
    }

    /// One channel of a stream, de-interleaved.
    func channel(_ channel: Int, stream: Int = 0) -> [Float] {
        let channels = max(1, streams[stream].channels)
        return samples(stream: stream).enumerated().filter { $0.offset % channels == channel }.map(\.element)
    }

    func guardSamplesIntact(stream: Int = 0) -> Bool {
        guard let pointer = storage[stream] else { return true }
        let guards = UnsafeBufferPointer(start: pointer + sampleCount(stream), count: streams[stream].guardSamples)
        return guards.allSatisfy { $0 == Self.guardValue }
    }
}

extension TapRenderer {
    func render(input: TestBufferList, output: TestBufferList) {
        render(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer)
    }
}

/// Interleaves per-channel sample arrays.
func interleave(_ channels: [Float]...) -> [Float] {
    let frames = channels[0].count
    return (0..<frames).flatMap { frame in channels.map { $0[frame] } }
}
