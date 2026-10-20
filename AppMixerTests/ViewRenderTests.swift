import AppKit
import AudioToolbox
import SwiftUI
import Testing

/// Evaluates every view body in each popover state, driven by a `Mixer` on the fake audio system.
/// These only check that rendering works; the snapshot tests check what it looks like.
/// Skipped without a window server session (e.g. over SSH) rather than failing.
@Suite("Views", .enabled(if: CGSessionCopyCurrentDictionary() != nil, "needs a window server session"))
@MainActor
struct ViewRenderTests {
    let music = TestFixtures.musicID
    let chime = TestFixtures.chimeID

    func render(_ view: some View, style: RowStyle) throws {
        let defaults = TestDefaults()
        defaults.set(style.rawValue, forKey: RowStyle.storageKey)
        let renderer = ImageRenderer(content: view.defaultAppStorage(defaults))
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test(arguments: RowStyle.allCases)
    func changedApps(style: RowStyle) throws {
        let h = MixerHarness()
        h.system.apps = [TestFixtures.music, TestFixtures.app(chime, processes: [201], isPlaying: true, isRegularApp: false)]
        let mixer = h.start()
        mixer.setVolume(0.4, for: music)
        mixer.setRoute(uid: "airpods", for: music)
        mixer.toggleMute(for: chime)

        try render(MixerView(mixer: mixer), style: style)
    }

    @Test(arguments: RowStyle.allCases)
    func disconnectedRoute(style: RowStyle) throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setRoute(uid: "airpods", for: music)
        h.system.devices = [TestFixtures.speakers]
        h.system.notify(.system, kAudioHardwarePropertyDevices)

        try render(MixerView(mixer: mixer), style: style)
    }

    @Test func unchangedApps() throws {
        try render(MixerView(mixer: MixerHarness().start()), style: .compact)
    }

    @Test func noApps() throws {
        let h = MixerHarness()
        h.system.apps = []
        try render(MixerView(mixer: h.start()), style: .compact)
    }

    @Test func noOutputDevice() throws {
        let h = MixerHarness()
        h.system.devices = []
        h.system.defaultDevice = nil
        try render(MixerView(mixer: h.start()), style: .standard)
    }

    @Test func permissionDenied() throws {
        let h = MixerHarness()
        h.tcc.status = .denied
        try render(MixerView(mixer: h.start()), style: .compact)
    }

    @Test func tapError() throws {
        let h = MixerHarness()
        let mixer = h.start()
        h.system.tapFailures = .max
        mixer.setVolume(0.5, for: music)
        #expect(mixer.lastError != nil)

        try render(MixerView(mixer: mixer), style: .compact)
        mixer.shutdown()
    }

    @Test(arguments: RowStyle.allCases)
    func settings(style: RowStyle) throws {
        try render(SettingsView(), style: style)
    }

    /// The previews' fixtures, including their generated icons, through the previews' own layout modifier.
    @Test(arguments: MixerFixture.allCases)
    func previewFixtures(fixture: MixerFixture) throws {
        let renderer = ImageRenderer(content: MixerView(mixer: fixture.makeMixer()).fixtureRowStyle(.standard))
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0 && image.size.height > 0)
        #expect(Fixtures.defaults(rowStyle: .standard).string(forKey: RowStyle.storageKey) == "standard")
    }
}
