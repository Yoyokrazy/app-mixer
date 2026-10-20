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

/// Owns the app list, per-app levels, and the taps that enforce them.
///
/// Apps at 100% are never tapped, so App Mixer adds zero latency or overhead until you actually turn
/// something down. A tap stays alive for as long as the app is a Core Audio client (not just while it's
/// playing), so short sounds like notifications are already at the right level when they start.
@Observable
@MainActor
final class Mixer {
    private(set) var apps: [AudioApp] = []
    private(set) var levels: [String: AppLevel]
    private(set) var lastError: String?
    let permission = CapturePermission()

    @ObservationIgnored private var allApps: [String: AudioApp] = [:]
    @ObservationIgnored private var taps: [String: AppTap] = [:]
    @ObservationIgnored private var pendingTeardowns: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var retries: [String: (attempt: Int, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var output: OutputDevice?
    @ObservationIgnored private var outputSampleRate: Double?
    @ObservationIgnored private var systemListeners: [PropertyListener] = []
    @ObservationIgnored private var outputRateListener: PropertyListener?
    @ObservationIgnored private var processListeners: [AudioObjectID: PropertyListener] = [:]
    @ObservationIgnored private var refreshScheduled = false

    private static let levelsKey = "levels"
    private let logger = Logger(subsystem: "com.yoyokrazy.AppMixer", category: "Mixer")

    init() {
        let saved = UserDefaults.standard.data(forKey: Self.levelsKey)
        levels = saved.flatMap { try? JSONDecoder().decode([String: AppLevel].self, from: $0) } ?? [:]
    }

    func start() {
        permission.onChange = { [weak self] in self?.syncAllTaps() }
        permission.requestIfNeeded()

        systemListeners = [
            PropertyListener(.system, kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.scheduleRefresh() },
            PropertyListener(.system, kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in self?.updateOutputDevice() },
        ].compactMap { $0 }

        updateOutputDevice()
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
        if let data = try? JSONEncoder().encode(levels) {
            UserDefaults.standard.set(data, forKey: Self.levelsKey)
        }
        syncTap(for: id)
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
        let scanned = AudioAppScanner.scan()
        allApps = Dictionary(uniqueKeysWithValues: scanned.map { ($0.id, $0) })

        // Dock apps with an audio connection are listed even when silent; background agents only while playing.
        let visible = scanned.filter { $0.isRegularApp || $0.isPlaying || !level(for: $0.id).isUnity }
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
            processListeners[object] = PropertyListener(object, kAudioProcessPropertyIsRunning) { [weak self] in
                self?.scheduleRefresh()
            }
        }

        syncAllTaps()
    }

    private func updateOutputDevice() {
        let id = AudioObjectID.defaultOutputDevice
        let device = id.isValid ? id.deviceUID.map { OutputDevice(id: id, uid: $0) } : nil
        guard device != output else { return }
        output = device
        outputSampleRate = device?.id.nominalSampleRate
        // A rate change (e.g. AirPods switching to the call profile) leaves the old aggregate running at the wrong rate.
        outputRateListener = device.flatMap { device in
            PropertyListener(device.id, kAudioDevicePropertyNominalSampleRate) { [weak self] in
                guard let self, let rate = device.id.nominalSampleRate, rate != self.outputSampleRate else { return }
                self.outputSampleRate = rate
                self.rebuildAllTaps()
            }
        }
        syncAllTaps()
    }

    // MARK: - Taps

    private func rebuildAllTaps() {
        shutdown()
        syncAllTaps()
    }

    private func syncAllTaps() {
        for id in Set(allApps.keys).union(taps.keys) {
            syncTap(for: id)
        }
    }

    private func syncTap(for id: String) {
        let level = level(for: id)
        guard var app = allApps[id], let output, permission.status == .authorized else {
            removeTap(for: id)
            return
        }

        if level.isUnity {
            // Hold the tap briefly at full gain so dragging around 100% doesn't churn taps.
            guard let tap = taps[id] else { return }
            tap.gain = level.gain
            if pendingTeardowns[id] == nil {
                pendingTeardowns[id] = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self.pendingTeardowns[id] = nil
                    if self.level(for: id).isUnity { self.removeTap(for: id) }
                }
            }
            return
        }

        pendingTeardowns.removeValue(forKey: id)?.cancel()

        // A helper can exit between the last scan and now; tapping a dead process object fails with '!obj'.
        let live = app.processes.filter { $0.processPID != nil }
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
            let tap = try AppTap(app: app, output: output, gain: level.gain)
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
            try? await Task.sleep(for: .milliseconds(250 << attempt))
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
