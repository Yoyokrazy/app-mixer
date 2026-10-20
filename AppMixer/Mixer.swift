import AppKit
import AudioToolbox
import os

struct AppLevel: Codable, Equatable {
    var volume: Double = 1
    var muted = false

    var isUnity: Bool { volume >= 1 && !muted }

    /// Square-law taper so the slider feels even across its range (50% ≈ -12 dB).
    var gain: Float { muted ? 0 : Float(volume * volume) }
}

/// An app's chosen output device. The name is kept so a disconnected device can still be shown.
struct Route: Codable, Equatable {
    var uid: String
    var name: String
}

/// Owns the app list, per-app levels and routes, and the taps that enforce them.
///
/// Apps at 100% on the default output are never tapped, so App Mixer adds zero latency or overhead until
/// you actually turn something down or route it elsewhere. A tap stays alive for as long as the app is a
/// Core Audio client (not just while it's playing), so short sounds like notifications are already at the
/// right level when they start.
@Observable
@MainActor
final class Mixer {
    private(set) var apps: [AudioApp] = []
    private(set) var levels: [String: AppLevel]
    private(set) var routes: [String: Route]
    private(set) var outputDevices: [OutputDevice] = []
    private(set) var defaultOutput: OutputDevice?
    private(set) var lastError: String?
    let permission: CapturePermission

    @ObservationIgnored private var allApps: [String: AudioApp] = [:]
    @ObservationIgnored private var taps: [String: any ProcessTap] = [:]
    @ObservationIgnored private var pendingTeardowns: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retries: [String: (attempt: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var sampleRates: [AudioDeviceID: Double] = [:]
    @ObservationIgnored private var rateListeners: [AudioDeviceID: AnyObject] = [:]
    @ObservationIgnored private var systemListeners: [AnyObject] = []
    @ObservationIgnored private var processListeners: [AudioObjectID: AnyObject] = [:]
    @ObservationIgnored private var refreshScheduled = false
    /// Previews and snapshot tests seed fixed state; it must never be rescanned from Core Audio or saved.
    @ObservationIgnored private var isFixture = false

    private static let levelsKey = "levels"
    private static let routesKey = "routes"
    private let logger = Logger(subsystem: "com.yoyokrazy.AppMixer", category: "Mixer")
    private let system: any AudioSystem
    private let defaults: UserDefaults
    /// Waits before tearing down a tap and between retries; injectable so tests control time.
    private let delay: @Sendable (Duration) async throws -> Void

    init(
        system: any AudioSystem = CoreAudioSystem(),
        defaults: UserDefaults = .standard,
        permission: CapturePermission = CapturePermission(),
        delay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.system = system
        self.defaults = defaults
        self.permission = permission
        self.delay = delay
        levels = defaults.data(forKey: Self.levelsKey).flatMap { try? JSONDecoder().decode([String: AppLevel].self, from: $0) } ?? [:]
        routes = defaults.data(forKey: Self.routesKey).flatMap { try? JSONDecoder().decode([String: Route].self, from: $0) } ?? [:]
    }

    func start() {
        permission.onChange = { [weak self] in self?.syncAllTaps() }
        permission.requestIfNeeded()

        systemListeners = [
            system.listen(to: .system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.scheduleRefresh() },
            system.listen(to: .system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.updateDevices() },
            system.listen(to: .system, kAudioHardwarePropertyDevices) { [weak self] in self?.updateDevices() },
        ].compactMap { $0 }

        updateDevices()
        refresh()
    }

    func shutdown() {
        for id in Set(taps.keys).union(pendingTeardowns.keys).union(retries.keys) {
            removeTap(for: id)
        }
    }

    // MARK: - Levels

    func level(for id: String) -> AppLevel {
        levels[id] ?? AppLevel()
    }

    func setVolume(_ volume: Double, for id: String) {
        var level = level(for: id)
        level.volume = min(max(volume, 0), 1)
        if level.volume > 0 { level.muted = false }
        setLevel(level, for: id)
    }

    func toggleMute(for id: String) {
        var level = level(for: id)
        level.muted.toggle()
        if !level.muted, level.volume == 0 { level.volume = 1 }
        setLevel(level, for: id)
    }

    private func setLevel(_ level: AppLevel, for id: String) {
        levels[id] = level.isUnity ? nil : level
        save(levels, forKey: Self.levelsKey)
        syncTap(for: id)
    }

    /// Clears every saved level and route: all apps back to 100% on the system output device.
    func resetAll() {
        levels = [:]
        routes = [:]
        save(levels, forKey: Self.levelsKey)
        save(routes, forKey: Self.routesKey)
        refresh()
    }

    var hasChanges: Bool {
        !levels.isEmpty || !routes.isEmpty
    }

    // MARK: - Routing

    func route(for id: String) -> Route? {
        routes[id]
    }

    /// Routes an app to a specific output device, or back to the system default with `nil`.
    func setRoute(uid: String?, for id: String) {
        guard uid != routes[id]?.uid else { return }
        if let uid {
            guard let device = outputDevices.first(where: { $0.uid == uid }) else { return }
            routes[id] = Route(uid: uid, name: device.name)
        } else {
            routes[id] = nil
        }
        save(routes, forKey: Self.routesKey)
        syncTap(for: id)
    }

    /// Where an app's audio plays: its routed device while that's connected, else the system default.
    func output(for id: String) -> OutputDevice? {
        if let route = routes[id], let device = outputDevices.first(where: { $0.uid == route.uid }) {
            return device
        }
        return defaultOutput
    }

    private func isRerouted(_ id: String) -> Bool {
        output(for: id)?.uid != defaultOutput?.uid
    }

    private func save(_ value: some Encodable, forKey key: String) {
        guard !isFixture else { return }
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    // MARK: - Discovery

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor in
            self.refreshScheduled = false
            self.refresh()
        }
    }

    func refresh() {
        guard !isFixture else { return }
        let scanned = system.scanApps()
        allApps = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })

        // Dock apps with an audio connection are listed even when silent; background agents only while
        // playing or when you've changed them.
        let visible = scanned.filter {
            $0.isRegularApp || $0.isPlaying || !level(for: $0.id).isUnity || routes[$0.id] != nil
        }
        if visible != apps {
            apps = visible
            logger.info("Listing \(visible.map(\.name).joined(separator: ", "), privacy: .public)")
        }

        let wanted = Set(scanned.flatMap(\.processes))
        for object in Array(processListeners.keys) where !wanted.contains(object) {
            processListeners[object] = nil
        }
        // IsRunningOutput never posts change notifications; IsRunning does whenever a process starts or stops IO.
        for object in wanted where processListeners[object] == nil {
            processListeners[object] = system.listen(to: object, kAudioProcessPropertyIsRunning) { [weak self] in
                self?.scheduleRefresh()
            }
        }

        syncAllTaps()
    }

    private func updateDevices() {
        let devices = system.outputDevices()
        let defaultDevice = system.defaultOutputDevice()
        if devices != outputDevices { outputDevices = devices }
        if defaultDevice != defaultOutput { defaultOutput = defaultDevice }

        // A rate change (e.g. AirPods switching to the call profile) leaves an aggregate running at the wrong
        // rate, so watch every device a tap could be playing to.
        var listeners: [AudioDeviceID: AnyObject] = [:]
        for device in devices + [defaultDevice].compactMap({ $0 }) where listeners[device.id] == nil {
            if let existing = rateListeners.removeValue(forKey: device.id) {
                listeners[device.id] = existing
                continue
            }
            sampleRates[device.id] = system.sampleRate(of: device.id)
            listeners[device.id] = system.listen(to: device.id, kAudioDevicePropertyNominalSampleRate) { [weak self] in
                self?.sampleRateChanged(device.id)
            }
        }
        rateListeners = listeners
        sampleRates = sampleRates.filter { listeners[$0.key] != nil }

        syncAllTaps()
    }

    private func sampleRateChanged(_ device: AudioDeviceID) {
        guard let rate = system.sampleRate(of: device), rate != sampleRates[device] else { return }
        sampleRates[device] = rate
        for id in taps.filter({ $0.value.outputID == device }).map(\.key) {
            removeTap(for: id)
        }
        syncAllTaps()
    }

    // MARK: - Taps

    private func syncAllTaps() {
        for id in Set(allApps.keys).union(taps.keys) {
            syncTap(for: id)
        }
    }

    private func syncTap(for id: String) {
        let level = level(for: id)
        guard var app = allApps[id], let output = output(for: id), permission.status == .authorized else {
            removeTap(for: id)
            return
        }

        if level.isUnity && !isRerouted(id) {
            guard let tap = taps[id] else { return }
            // The app's audio belongs on the default device again; a tap pointed elsewhere must go now.
            guard tap.outputUID == output.uid else {
                removeTap(for: id)
                return
            }
            // Hold the tap briefly at full gain so dragging around 100% doesn't churn taps.
            tap.gain = level.gain
            if pendingTeardowns[id] == nil {
                pendingTeardowns[id] = Task { @MainActor in
                    try? await self.delay(.seconds(1))
                    guard !Task.isCancelled else { return }
                    self.pendingTeardowns[id] = nil
                    if self.level(for: id).isUnity, !self.isRerouted(id) { self.removeTap(for: id) }
                }
            }
            return
        }

        pendingTeardowns.removeValue(forKey: id)?.cancel()

        // A helper can exit between the last scan and now; tapping a dead process object fails with '!obj'.
        let live = app.processes.filter { system.isProcessAlive($0) }
        guard !live.isEmpty else {
            removeTap(for: id)
            return
        }
        if live != app.processes {
            app.processes = live
            allApps[id] = app
        }

        if let tap = taps[id], tap.processes == app.processes, tap.outputUID == output.uid {
            tap.gain = level.gain
            return
        }

        // Make before break: if the new tap fails (e.g. a helper exits mid-setup), the old one keeps the app
        // at its level instead of letting it jump back to full volume.
        do {
            let tap = try system.makeTap(for: app, on: output, gain: level.gain)
            taps.updateValue(tap, forKey: id)?.destroy()
            retries.removeValue(forKey: id)?.task.cancel()
            lastError = nil
        } catch {
            logger.error("Tap failed for \(app.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            lastError = "\(app.name): \(error.localizedDescription)"
            scheduleRetry(for: id)
        }
    }

    /// Retries after 0.5, 1, 2, 4, then 8 seconds; resets on success.
    private func scheduleRetry(for id: String) {
        let attempt = (retries[id]?.attempt ?? 0) + 1
        guard attempt <= 5 else { return }
        retries[id]?.task.cancel()
        let task = Task { @MainActor in
            try? await self.delay(.milliseconds(250 << attempt))
            guard !Task.isCancelled else { return }
            self.syncTap(for: id)
        }
        retries[id] = (attempt, task)
    }

    private func removeTap(for id: String) {
        pendingTeardowns.removeValue(forKey: id)?.cancel()
        retries.removeValue(forKey: id)?.task.cancel()
        taps.removeValue(forKey: id)?.destroy()
    }
}

#if DEBUG
extension Mixer {
    /// A mixer with fixed state for SwiftUI previews and snapshot tests. It is never started, never rescans
    /// Core Audio (so `onAppear` can't swap in the machine's real apps), and never saves to `UserDefaults`.
    convenience init(
        fixtureApps apps: [AudioApp],
        levels: [String: AppLevel] = [:],
        routes: [String: Route] = [:],
        outputDevices: [OutputDevice] = [],
        defaultOutput: OutputDevice? = nil,
        lastError: String? = nil,
        permission: CapturePermission.Status = .authorized
    ) {
        self.init()
        isFixture = true
        self.apps = apps
        self.levels = levels
        self.routes = routes
        self.outputDevices = outputDevices
        self.defaultOutput = defaultOutput
        self.lastError = lastError
        self.permission.pin(permission)
    }
}
#endif
