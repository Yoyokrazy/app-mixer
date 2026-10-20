import AppKit
import Testing

/// The DEBUG fixture mode behind the previews and snapshot tests: seeded state that never rescans Core Audio,
/// never saves, and never asks TCC.
@Suite("Fixture mode")
@MainActor
struct FixtureModeTests {
    let music = TestFixtures.musicID

    @Test func seedsTheGivenState() {
        let mixer = Mixer(
            fixtureApps: [TestFixtures.music],
            levels: [music: AppLevel(volume: 0.5)],
            routes: [music: Route(uid: "airpods", name: "AirPods Pro")],
            outputDevices: [TestFixtures.speakers, TestFixtures.airPods],
            defaultOutput: TestFixtures.speakers,
            lastError: "Music: Couldn't tap Music",
            permission: .denied
        )

        #expect(mixer.apps == [TestFixtures.music])
        #expect(mixer.level(for: music) == AppLevel(volume: 0.5))
        #expect(mixer.route(for: music) == Route(uid: "airpods", name: "AirPods Pro"))
        #expect(mixer.output(for: music) == TestFixtures.airPods)
        #expect(mixer.defaultOutput == TestFixtures.speakers)
        #expect(mixer.lastError == "Music: Couldn't tap Music")
        #expect(mixer.permission.status == .denied)
        #expect(mixer.hasChanges)
    }

    @Test func defaultsToAnAuthorizedMixerWithNothingChanged() {
        let mixer = Mixer(fixtureApps: [])
        #expect(mixer.apps.isEmpty)
        #expect(!mixer.hasChanges)
        #expect(mixer.outputDevices.isEmpty)
        #expect(mixer.defaultOutput == nil)
        #expect(mixer.lastError == nil)
        #expect(mixer.permission.status == .authorized)
    }

    @Test func neverRescansCoreAudio() {
        let mixer = Mixer(fixtureApps: [TestFixtures.music])
        mixer.refresh()
        #expect(mixer.apps == [TestFixtures.music])
    }

    /// Fixture mixers use the process's standard defaults (the test runner's, not App Mixer's); this only reads them.
    @Test func changesStayInMemory() {
        let before = (UserDefaults.standard.data(forKey: "levels"), UserDefaults.standard.data(forKey: "routes"))
        let mixer = Mixer(fixtureApps: [TestFixtures.music], outputDevices: [TestFixtures.speakers, TestFixtures.airPods], defaultOutput: TestFixtures.speakers)

        mixer.setVolume(0.3, for: music)
        mixer.setRoute(uid: "airpods", for: music)
        #expect(mixer.level(for: music).volume == 0.3)
        #expect(mixer.route(for: music)?.uid == "airpods")

        mixer.resetAll()
        #expect(!mixer.hasChanges)
        #expect(mixer.apps == [TestFixtures.music])
        #expect(UserDefaults.standard.data(forKey: "levels") == before.0)
        #expect(UserDefaults.standard.data(forKey: "routes") == before.1)
    }

    @Test func pinnedPermissionIsNeverReplaced() {
        let mixer = Mixer(fixtureApps: [], permission: .denied)
        mixer.permission.refresh()
        mixer.permission.requestIfNeeded()
        #expect(mixer.permission.status == .denied)
    }

    @Test(arguments: MixerFixture.allCases)
    func everyPreviewFixtureBuilds(fixture: MixerFixture) {
        let mixer = fixture.makeMixer()
        #expect(mixer.outputDevices == Fixtures.devices)
        #expect(mixer.defaultOutput == Fixtures.speakers)
        #expect(mixer.apps.allSatisfy { $0.icon.size == NSSize(width: 64, height: 64) })
        switch fixture {
        case .mixed: #expect(mixer.hasChanges)
        case .unchanged, .empty, .permissionDenied: #expect(!mixer.hasChanges)
        case .error: #expect(mixer.lastError != nil)
        }
    }
}
