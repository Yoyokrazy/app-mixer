import AppKit
import os

/// "System Audio Recording" (kTCCServiceAudioCapture) permission. Without it, a process tap still mutes
/// the app but only delivers silence, so App Mixer must never tap while this is denied.
///
/// There's no public API to query or request it, so this calls the private TCC framework. If the SPI ever
/// disappears we assume access and let macOS prompt on first tap.
@Observable
@MainActor
final class CapturePermission {
    enum Status { case notDetermined, authorized, denied }

    /// The TCC calls, swappable so tests can drive this without touching real privacy settings.
    struct Access {
        var preflight: @MainActor () -> Status
        var request: @MainActor (_ completion: @escaping @Sendable (Bool) -> Void) -> Void
    }

    private(set) var status: Status = .notDetermined
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let logger = Logger(subsystem: "com.yoyokrazy.AppMixer", category: "Permission")
    @ObservationIgnored private let access: Access
    /// Previews and snapshot tests pin a status that must not be replaced by this machine's real one.
    @ObservationIgnored private var isPinned = false

    init(access: Access = CapturePermission.tcc) {
        self.access = access
    }

    func refresh() {
        guard !isPinned else { return }
        update(access.preflight())
    }

    func requestIfNeeded() {
        refresh()
        guard status == .notDetermined else { return }
        // TCC calls back on its own queue; @Sendable keeps Swift 6 from assuming main-actor isolation and trapping.
        access.request { @Sendable granted in
            Task { @MainActor in self.update(granted ? .authorized : .denied) }
        }
    }

    func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    private func update(_ newStatus: Status) {
        guard newStatus != status else { return }
        status = newStatus
        logger.info("System Audio Recording permission: \(String(describing: newStatus), privacy: .public)")
        onChange?()
    }

    // MARK: - TCC SPI

    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    static let tcc = Access(
        preflight: preflight,
        request: { completion in
            guard let request = requestFunction else { return }
            request(service, nil, completion)
        }
    )

    static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW),
              let symbol = dlsym(handle, name)
        else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static var requestFunction: RequestFunction? { symbol("TCCAccessRequest", as: RequestFunction.self) }

    private static func preflight() -> Status {
        guard let preflight = symbol("TCCAccessPreflight", as: PreflightFunction.self) else { return .authorized }
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }
}

#if DEBUG
extension CapturePermission {
    /// Fixes the status for previews and snapshot tests; TCC is never queried afterwards.
    func pin(_ status: Status) {
        isPinned = true
        self.status = status
    }
}
#endif
