#if DEBUG
import AppKit
import AudioToolbox
import SwiftUI

/// Fixed apps, devices, and mixer states shared by the SwiftUI previews and the snapshot tests.
///
/// Nothing here comes from the machine (no NSWorkspace icons, no Core Audio devices, no saved settings),
/// so a fixture looks the same everywhere it's rendered.
@MainActor
enum Fixtures {
    // MARK: Devices

    static let speakers = OutputDevice(id: 101, uid: "fixture-speakers", name: "MacBook Pro Speakers", transport: kAudioDeviceTransportTypeBuiltIn)
    static let airPods = OutputDevice(id: 102, uid: "fixture-airpods", name: "AirPods Pro", transport: kAudioDeviceTransportTypeBluetooth)
    static let display = OutputDevice(id: 103, uid: "fixture-display", name: "Studio Display", transport: kAudioDeviceTransportTypeDisplayPort)
    static let devices = [speakers, airPods, display]

    /// A route to a device that isn't connected.
    static let usbDACRoute = Route(uid: "fixture-usb-dac", name: "USB DAC")

    // MARK: Apps

    static let browser = app("fixture.browser", "Browser", .globe, top: (0.30, 0.68, 1.00), bottom: (0.05, 0.38, 0.92))
    static let meetings = app("fixture.meetings", "Meetings", .camera, top: (0.32, 0.84, 0.50), bottom: (0.08, 0.60, 0.30))
    static let music = app("fixture.music", "Music", .note, top: (1.00, 0.36, 0.45), bottom: (0.86, 0.10, 0.30))
    static let podcasts = app("fixture.podcasts", "Podcasts", .signal, top: (0.78, 0.48, 1.00), bottom: (0.52, 0.20, 0.86))

    private static func app(
        _ id: String,
        _ name: String,
        _ glyph: FixtureIcon.Glyph,
        top: (Double, Double, Double),
        bottom: (Double, Double, Double)
    ) -> AudioApp {
        AudioApp(
            id: id,
            name: name,
            icon: FixtureIcon(glyph: glyph, top: top, bottom: bottom).image,
            processes: [],
            isPlaying: true,
            isRegularApp: true
        )
    }

    // MARK: Settings

    /// Scratch defaults holding only the given layout, so `@AppStorage` never reads or writes the app's real settings.
    /// Named by a path, the suite lives in the temporary directory rather than ~/Library/Preferences.
    static func defaults(rowStyle: RowStyle) -> UserDefaults {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppMixerFixtures")
            .appendingPathComponent(rowStyle.rawValue)
            .path
        let defaults = UserDefaults(suiteName: path)!
        defaults.set(rowStyle.rawValue, forKey: RowStyle.storageKey)
        return defaults
    }
}

/// A mixer state worth looking at.
@MainActor
enum MixerFixture: String, CaseIterable {
    /// One app of each kind: untouched, turned down and routed, muted, and routed to a disconnected device.
    case mixed
    /// Every app at 100% on the system output, so there's nothing to reset.
    case unchanged
    /// No app has an audio connection.
    case empty
    /// System Audio Recording is denied.
    case permissionDenied
    /// A tap failed.
    case error

    func makeMixer() -> Mixer {
        switch self {
        case .mixed:
            Mixer(
                fixtureApps: [Fixtures.browser, Fixtures.meetings, Fixtures.music, Fixtures.podcasts],
                levels: [
                    Fixtures.meetings.id: AppLevel(volume: 0.4),
                    Fixtures.music.id: AppLevel(volume: 0.7, muted: true),
                    Fixtures.podcasts.id: AppLevel(volume: 0.65),
                ],
                routes: [
                    Fixtures.meetings.id: Route(uid: Fixtures.airPods.uid, name: Fixtures.airPods.name),
                    Fixtures.podcasts.id: Fixtures.usbDACRoute,
                ],
                outputDevices: Fixtures.devices,
                defaultOutput: Fixtures.speakers
            )
        case .unchanged:
            Mixer(
                fixtureApps: [Fixtures.browser, Fixtures.music],
                outputDevices: Fixtures.devices,
                defaultOutput: Fixtures.speakers
            )
        case .empty:
            Mixer(fixtureApps: [], outputDevices: Fixtures.devices, defaultOutput: Fixtures.speakers)
        case .permissionDenied:
            Mixer(
                fixtureApps: [Fixtures.browser, Fixtures.music],
                outputDevices: Fixtures.devices,
                defaultOutput: Fixtures.speakers,
                permission: .denied
            )
        case .error:
            Mixer(
                fixtureApps: [Fixtures.browser, Fixtures.music],
                levels: [Fixtures.music.id: AppLevel(volume: 0.5)],
                outputDevices: Fixtures.devices,
                defaultOutput: Fixtures.speakers,
                lastError: "Music: Couldn't create aggregate device (OSStatus 1852797029)"
            )
        }
    }
}

/// A flat, generated app icon: a gradient rounded square with a simple white glyph.
private struct FixtureIcon {
    enum Glyph { case globe, camera, note, signal }

    let glyph: Glyph
    let top: (Double, Double, Double)
    let bottom: (Double, Double, Double)

    var image: NSImage {
        let glyph = glyph
        let top = NSColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1)
        let bottom = NSColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)
        return NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 13, yRadius: 13)
            NSGradient(starting: top, ending: bottom)?.draw(in: tile, angle: -90)
            NSColor.white.set()
            Self.path(for: glyph).fill()
            return true
        }
    }

    private static func path(for glyph: Glyph) -> NSBezierPath {
        switch glyph {
        case .globe:
            let path = NSBezierPath()
            path.appendOval(in: NSRect(x: 16, y: 16, width: 32, height: 32))
            path.appendOval(in: NSRect(x: 21, y: 21, width: 22, height: 22))
            path.windingRule = .evenOdd
            path.append(NSBezierPath(rect: NSRect(x: 16, y: 30.5, width: 32, height: 3)))
            path.append(NSBezierPath(rect: NSRect(x: 30.5, y: 16, width: 3, height: 32)))
            return path
        case .camera:
            let path = NSBezierPath(roundedRect: NSRect(x: 14, y: 22, width: 26, height: 20), xRadius: 4, yRadius: 4)
            path.move(to: NSPoint(x: 42, y: 32))
            path.line(to: NSPoint(x: 51, y: 24))
            path.line(to: NSPoint(x: 51, y: 40))
            path.close()
            return path
        case .note:
            let path = NSBezierPath(ovalIn: NSRect(x: 18, y: 16, width: 15, height: 12))
            path.append(NSBezierPath(rect: NSRect(x: 29, y: 22, width: 4, height: 26)))
            path.append(NSBezierPath(rect: NSRect(x: 29, y: 42, width: 15, height: 6)))
            return path
        case .signal:
            let path = NSBezierPath(ovalIn: NSRect(x: 26, y: 26, width: 12, height: 12))
            for (inset, width) in [(14.0, 4.0), (6.0, 4.0)] {
                let ring = NSBezierPath(ovalIn: NSRect(x: inset, y: inset, width: 64 - 2 * inset, height: 64 - 2 * inset))
                ring.append(NSBezierPath(ovalIn: NSRect(x: inset + width, y: inset + width, width: 64 - 2 * (inset + width), height: 64 - 2 * (inset + width))).reversed)
                path.append(ring)
            }
            return path
        }
    }
}

extension View {
    /// Renders with the given layout without touching the app's saved `rowStyle`.
    func fixtureRowStyle(_ style: RowStyle) -> some View {
        defaultAppStorage(Fixtures.defaults(rowStyle: style))
    }
}

// MARK: - Previews

#Preview("Mixed, compact") {
    MixerView(mixer: MixerFixture.mixed.makeMixer()).fixtureRowStyle(.compact)
}

#Preview("Mixed, standard") {
    MixerView(mixer: MixerFixture.mixed.makeMixer()).fixtureRowStyle(.standard)
}

#Preview("Unchanged") {
    MixerView(mixer: MixerFixture.unchanged.makeMixer()).fixtureRowStyle(.compact)
}

#Preview("Empty") {
    MixerView(mixer: MixerFixture.empty.makeMixer()).fixtureRowStyle(.compact)
}

#Preview("Permission denied") {
    MixerView(mixer: MixerFixture.permissionDenied.makeMixer()).fixtureRowStyle(.standard)
}

#Preview("Error") {
    MixerView(mixer: MixerFixture.error.makeMixer()).fixtureRowStyle(.compact)
}

#Preview("Settings") {
    SettingsView().fixtureRowStyle(.compact)
}
#endif
