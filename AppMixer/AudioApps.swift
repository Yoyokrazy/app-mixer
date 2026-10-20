import AppKit
import AudioToolbox

struct AudioApp: Identifiable, Equatable {
    /// Bundle ID of the owning app; also the key settings are saved under.
    let id: String
    let name: String
    let icon: NSImage
    /// Every Core Audio process object belonging to this app (main process plus helpers), sorted.
    var processes: [AudioObjectID]
    var isPlaying: Bool
    /// A Dock app (as opposed to a menu bar agent or system UI like loginwindow or Control Center).
    let isRegularApp: Bool

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.processes == rhs.processes
            && lhs.isPlaying == rhs.isPlaying && lhs.isRegularApp == rhs.isRegularApp
    }
}

/// The parts of `NSRunningApplication` the scanner uses; lets tests stand in fake apps.
@MainActor
protocol RunningApp {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String? { get }
    var bundleURL: URL? { get }
    var localizedName: String? { get }
    var icon: NSImage? { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
}

extension NSRunningApplication: RunningApp {}

/// Groups Core Audio's process objects into user-facing apps.
///
/// A process shows up in Core Audio's list once it opens an audio connection and stays there while it
/// runs, even when silent. That's what makes "apps that could play sound" (e.g. a browser paused on a
/// video) discoverable; apps that have never touched audio aren't listed until they do.
@MainActor
enum AudioAppScanner {
    static func scan() -> [AudioApp] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let running = NSWorkspace.shared.runningApplications
        return scan(processes: AudioObjectID.processList, running: running, ownPID: ownPID)
    }

    /// `scan()` with every system lookup injectable.
    static func scan<App: RunningApp>(
        processes: [AudioObjectID],
        running runningApps: [App],
        ownPID: pid_t,
        pid: (AudioObjectID) -> pid_t? = { $0.processPID },
        isPlaying: (AudioObjectID) -> Bool = { $0.isRunningOutput },
        responsiblePID: (pid_t) -> pid_t? = responsiblePID(for:),
        parentPID: (pid_t) -> pid_t? = parentPID(of:)
    ) -> [AudioApp] {
        let running = Dictionary(
            runningApps.map { ($0.processIdentifier, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var apps: [String: AudioApp] = [:]
        for object in processes {
            guard let pid = pid(object), pid > 0, pid != ownPID,
                  let owner = owningApp(of: pid, running: running, responsiblePID: responsiblePID, parentPID: parentPID),
                  owner.processIdentifier != ownPID,
                  let bundleID = owner.bundleIdentifier
            else { continue }

            let playing = isPlaying(object)
            if var app = apps[bundleID] {
                app.processes.append(object)
                app.isPlaying = app.isPlaying || playing
                apps[bundleID] = app
            } else {
                apps[bundleID] = AudioApp(
                    id: bundleID,
                    name: owner.localizedName ?? bundleID,
                    icon: owner.icon ?? NSWorkspace.shared.icon(for: .application),
                    processes: [object],
                    isPlaying: playing,
                    isRegularApp: owner.activationPolicy == .regular
                )
            }
        }

        return apps.values
            .map { app in
                var app = app
                app.processes.sort()
                return app
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Resolves helpers (Safari's WebKit GPU process, Chrome's audio service, ...) to the app the user sees.
    /// Daemons with no owning app (coreaudiod, systemsoundserverd, ...) resolve to nil and are skipped.
    static func owningApp<App: RunningApp>(
        of pid: pid_t,
        running: [pid_t: App],
        responsiblePID: (pid_t) -> pid_t?,
        parentPID: (pid_t) -> pid_t?
    ) -> App? {
        func topLevelApp(_ pid: pid_t) -> App? {
            guard let app = running[pid], let url = app.bundleURL else { return nil }
            // Helpers often live in their own .app nested inside the real one, e.g. "Google Chrome Helper.app".
            let appComponents = url.pathComponents.filter { $0.hasSuffix(".app") }
            return appComponents.count == 1 ? app : nil
        }

        if let app = topLevelApp(pid) { return app }
        if let responsible = responsiblePID(pid), let app = topLevelApp(responsible) { return app }

        var current = pid
        var visited: Set<pid_t> = []
        while current > 1, visited.insert(current).inserted {
            guard let parent = parentPID(current), parent != current else { break }
            if let app = topLevelApp(parent) { return app }
            current = parent
        }
        return nil
    }

    private typealias ResponsibilityFunction = @convention(c) (pid_t) -> pid_t

    /// The same private libsystem call Activity Monitor uses to attribute XPC services to their app.
    nonisolated static func responsiblePID(for pid: pid_t) -> pid_t? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        let responsible = unsafeBitCast(symbol, to: ResponsibilityFunction.self)(pid)
        return responsible > 0 && responsible != pid ? responsible : nil
    }

    nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}
