import AppKit
import AudioToolbox
import Observation
import Testing

/// A `Mixer` wired to fakes: no audio hardware, permission prompts, real time, or real defaults.
@MainActor
final class MixerHarness {
    let system = FakeAudioSystem()
    let tcc = FakeTCC()
    let delay = ManualDelay()
    let defaults = TestDefaults()
    private(set) lazy var permission = CapturePermission(access: tcc.access)
    private(set) lazy var mixer = makeMixer()

    init() {
        system.devices = [TestFixtures.speakers, TestFixtures.airPods]
        system.defaultDevice = TestFixtures.speakers
        system.sampleRates = [TestFixtures.speakers.id: 48_000, TestFixtures.airPods.id: 48_000]
        system.apps = [TestFixtures.music, TestFixtures.chime]
    }

    /// Another mixer sharing this one's defaults, as after a relaunch.
    func makeMixer() -> Mixer {
        Mixer(system: system, defaults: defaults, permission: permission, delay: { [delay] in try await delay.wait($0) })
    }

    @discardableResult
    func start() -> Mixer {
        mixer.start()
        return mixer
    }

    func savedLevels() throws -> [String: AppLevel] {
        try JSONDecoder().decode([String: AppLevel].self, from: #require(defaults.data(forKey: "levels")))
    }

    func savedRoutes() throws -> [String: Route] {
        try JSONDecoder().decode([String: Route].self, from: #require(defaults.data(forKey: "routes")))
    }

    func save(levels: [String: AppLevel] = [:], routes: [String: Route] = [:]) throws {
        defaults.set(try JSONEncoder().encode(levels), forKey: "levels")
        defaults.set(try JSONEncoder().encode(routes), forKey: "routes")
    }

    func tap(_ appID: String = TestFixtures.musicID) -> FakeTap? {
        system.liveTap(for: appID)
    }
}

@Suite("Mixer")
@MainActor
struct MixerTests {
    let music = TestFixtures.musicID
    let chime = TestFixtures.chimeID

    // MARK: - Startup

    @Test func startAsksForPermissionAndListensToTheSystem() {
        let h = MixerHarness()
        h.tcc.status = .notDetermined
        let mixer = h.start()

        #expect(h.tcc.requestCount == 1)
        #expect(h.system.listenerCount(on: .system, kAudioHardwarePropertyProcessObjectList) == 1)
        #expect(h.system.listenerCount(on: .system, kAudioHardwarePropertyDefaultOutputDevice) == 1)
        #expect(h.system.listenerCount(on: .system, kAudioHardwarePropertyDevices) == 1)
        #expect(mixer.outputDevices == [TestFixtures.speakers, TestFixtures.airPods])
        #expect(mixer.defaultOutput == TestFixtures.speakers)
        #expect(h.system.scanCount == 1)
        #expect(mixer.apps.map(\.id) == [music])
    }

    @Test func startWorksWhenListenersCannotRegister() {
        let h = MixerHarness()
        h.system.listenersFail = true
        let mixer = h.start()

        #expect(mixer.outputDevices.count == 2)
        #expect(mixer.apps.map(\.id) == [music])
    }

    @Test func watchesEveryProcessOfEveryScannedApp() {
        let h = MixerHarness()
        h.start()

        for process: AudioObjectID in [101, 102, 201] {
            #expect(h.system.listenerCount(on: process, kAudioProcessPropertyIsRunning) == 1)
        }
    }

    @Test func stopsWatchingProcessesThatGoAway() {
        let h = MixerHarness()
        let mixer = h.start()

        h.system.apps = [TestFixtures.chime]
        mixer.refresh()

        #expect(h.system.listenerCount(on: 101, kAudioProcessPropertyIsRunning) == 0)
        #expect(h.system.listenerCount(on: 102, kAudioProcessPropertyIsRunning) == 0)
        #expect(h.system.listenerCount(on: 201, kAudioProcessPropertyIsRunning) == 1)
        #expect(h.system.registrationCount(on: 201, kAudioProcessPropertyIsRunning) == 1)
    }

    // MARK: - Persistence

    @Test func loadsSavedLevelsAndRoutes() throws {
        let h = MixerHarness()
        try h.save(
            levels: [music: AppLevel(volume: 0.4, muted: true)],
            routes: [music: Route(uid: "airpods", name: "AirPods Pro")]
        )

        #expect(h.mixer.level(for: music) == AppLevel(volume: 0.4, muted: true))
        #expect(h.mixer.route(for: music) == Route(uid: "airpods", name: "AirPods Pro"))
        #expect(h.mixer.hasChanges)
    }

    @Test func ignoresUnreadableSavedData() {
        let h = MixerHarness()
        h.defaults.set(Data("not json".utf8), forKey: "levels")
        h.defaults.set("wrong type", forKey: "routes")

        #expect(h.mixer.levels.isEmpty)
        #expect(h.mixer.routes.isEmpty)
        #expect(!h.mixer.hasChanges)
    }

    @Test func savesLevelsAndRoutesForTheNextLaunch() throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.3, for: music)
        mixer.toggleMute(for: chime)
        mixer.setRoute(uid: "airpods", for: music)

        #expect(try h.savedLevels() == [music: AppLevel(volume: 0.3), chime: AppLevel(volume: 1, muted: true)])
        #expect(try h.savedRoutes() == [music: Route(uid: "airpods", name: "AirPods Pro")])

        let relaunched = h.makeMixer()
        #expect(relaunched.levels == mixer.levels)
        #expect(relaunched.routes == mixer.routes)
    }

    @Test func doesNotTouchStandardDefaults() {
        let h = MixerHarness()
        let before = UserDefaults.standard.object(forKey: "levels") as? Data
        h.start().setVolume(0.5, for: music)
        #expect(UserDefaults.standard.object(forKey: "levels") as? Data == before)
    }

    // MARK: - Levels

    @Test func unknownAppsAreAtUnity() {
        let h = MixerHarness()
        #expect(h.mixer.level(for: "com.example.never-seen") == AppLevel())
    }

    @Test(arguments: [(-0.5, 0.0), (0.0, 0.0), (0.42, 0.42), (1.0, 1.0), (1.7, 1.0)])
    func volumeIsClamped(requested: Double, stored: Double) {
        let h = MixerHarness()
        h.mixer.setVolume(requested, for: music)
        #expect(h.mixer.level(for: music).volume == stored)
    }

    @Test func unityLevelsAreNotStored() throws {
        let h = MixerHarness()
        h.mixer.setVolume(0.5, for: music)
        #expect(h.mixer.levels.keys.contains(music))

        h.mixer.setVolume(1, for: music)
        #expect(h.mixer.levels.isEmpty)
        #expect(try h.savedLevels().isEmpty)
        #expect(!h.mixer.hasChanges)
    }

    @Test func raisingTheVolumeUnmutes() {
        let h = MixerHarness()
        h.mixer.toggleMute(for: music)
        #expect(h.mixer.level(for: music).muted)

        h.mixer.setVolume(0, for: music)
        #expect(h.mixer.level(for: music).muted, "dragging to zero keeps it muted")

        h.mixer.setVolume(0.3, for: music)
        #expect(h.mixer.level(for: music) == AppLevel(volume: 0.3, muted: false))
    }

    @Test func muteTogglesAndKeepsTheVolume() {
        let h = MixerHarness()
        h.mixer.setVolume(0.6, for: music)
        h.mixer.toggleMute(for: music)
        #expect(h.mixer.level(for: music) == AppLevel(volume: 0.6, muted: true))
        h.mixer.toggleMute(for: music)
        #expect(h.mixer.level(for: music) == AppLevel(volume: 0.6, muted: false))
    }

    @Test func unmutingAtZeroRestoresFullVolume() {
        let h = MixerHarness()
        h.mixer.setVolume(0, for: music)
        h.mixer.toggleMute(for: music)
        h.mixer.toggleMute(for: music)

        #expect(h.mixer.level(for: music) == AppLevel())
        #expect(h.mixer.levels.isEmpty)
    }

    // MARK: - Routing

    @Test func routesToAConnectedDevice() throws {
        let h = MixerHarness()
        let mixer = h.start()

        mixer.setRoute(uid: "airpods", for: music)

        #expect(mixer.route(for: music) == Route(uid: "airpods", name: "AirPods Pro"))
        #expect(mixer.output(for: music) == TestFixtures.airPods)
        #expect(mixer.hasChanges)
        #expect(try h.savedRoutes() == [music: Route(uid: "airpods", name: "AirPods Pro")])
    }

    @Test func ignoresRoutesToUnknownDevices() {
        let h = MixerHarness()
        let mixer = h.start()

        mixer.setRoute(uid: "no-such-device", for: music)

        #expect(mixer.route(for: music) == nil)
        #expect(h.defaults.data(forKey: "routes") == nil)
    }

    @Test func settingTheSameRouteAgainIsANoOp() {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setRoute(uid: "airpods", for: music)
        let tap = h.tap()
        h.defaults.removeObject(forKey: "routes")

        mixer.setRoute(uid: "airpods", for: music)

        #expect(h.defaults.data(forKey: "routes") == nil, "not saved again")
        #expect(h.tap() === tap)
        #expect(h.system.taps.count == 1)
    }

    @Test func clearingARouteFollowsTheSystemDefault() throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setRoute(uid: "airpods", for: music)

        mixer.setRoute(uid: nil, for: music)

        #expect(mixer.route(for: music) == nil)
        #expect(mixer.output(for: music) == TestFixtures.speakers)
        #expect(try h.savedRoutes().isEmpty)
    }

    @Test func outputIsTheDefaultUnlessRoutedToAConnectedDevice() {
        let h = MixerHarness()
        let mixer = h.start()
        #expect(mixer.output(for: music) == TestFixtures.speakers)

        mixer.setRoute(uid: "airpods", for: music)
        #expect(mixer.output(for: music) == TestFixtures.airPods)

        h.system.devices = [TestFixtures.speakers]
        h.system.notify(.system, kAudioHardwarePropertyDevices)
        #expect(mixer.output(for: music) == TestFixtures.speakers)
        #expect(mixer.route(for: music)?.name == "AirPods Pro", "the route survives a disconnect")

        h.system.devices = [TestFixtures.speakers, TestFixtures.airPods]
        h.system.notify(.system, kAudioHardwarePropertyDevices)
        #expect(mixer.output(for: music) == TestFixtures.airPods)
    }

    @Test func noOutputWithoutADefaultDevice() {
        let h = MixerHarness()
        h.system.defaultDevice = nil
        #expect(h.start().output(for: music) == nil)
    }

    // MARK: - Visibility

    @Test func listsDockAppsEvenWhenSilent() {
        let h = MixerHarness()
        #expect(h.start().apps.map(\.id) == [music])
    }

    @Test func listsBackgroundAgentsWhilePlaying() {
        let h = MixerHarness()
        h.system.apps = [TestFixtures.music, TestFixtures.app(chime, processes: [201], isPlaying: true, isRegularApp: false)]
        #expect(h.start().apps.map(\.id) == [music, chime])
    }

    @Test func listsBackgroundAgentsYouChanged() {
        let h = MixerHarness()
        let mixer = h.start()

        mixer.setVolume(0.5, for: chime)
        mixer.refresh()
        #expect(mixer.apps.map(\.id) == [music, chime])

        mixer.setVolume(1, for: chime)
        mixer.refresh()
        #expect(mixer.apps.map(\.id) == [music])

        mixer.setRoute(uid: "airpods", for: chime)
        mixer.refresh()
        #expect(mixer.apps.map(\.id) == [music, chime])
    }

    @Test func appListOnlyChangesWhenItReallyDoes() {
        let h = MixerHarness()
        let mixer = h.start()

        let changed = Flag()
        withObservationTracking { _ = mixer.apps } onChange: { changed.set() }
        mixer.refresh()
        #expect(!changed.isSet)

        h.system.apps = [TestFixtures.app(music, processes: [101, 102], isPlaying: true), TestFixtures.chime]
        mixer.refresh()
        #expect(changed.isSet)
    }

    @Test func deviceListOnlyChangesWhenItReallyDoes() {
        let h = MixerHarness()
        let mixer = h.start()

        let changed = Flag()
        withObservationTracking {
            _ = mixer.outputDevices
            _ = mixer.defaultOutput
        } onChange: { changed.set() }
        h.system.notify(.system, kAudioHardwarePropertyDevices)
        #expect(!changed.isSet)

        h.system.defaultDevice = TestFixtures.airPods
        h.system.notify(.system, kAudioHardwarePropertyDefaultOutputDevice)
        #expect(changed.isSet)
    }

    // MARK: - Discovery notifications

    @Test func processListChangesAreCoalescedIntoOneRescan() async {
        let h = MixerHarness()
        h.start()

        for _ in 0..<3 { h.system.notify(.system, kAudioHardwarePropertyProcessObjectList) }

        #expect(await eventually { h.system.scanCount == 2 })
        await settle()
        #expect(h.system.scanCount == 2)

        h.system.notify(.system, kAudioHardwarePropertyProcessObjectList)
        #expect(await eventually { h.system.scanCount == 3 })
    }

    @Test func processStartingOrStoppingIORescans() async {
        let h = MixerHarness()
        let mixer = h.start()
        h.system.apps = [TestFixtures.app(music, processes: [101, 102], isPlaying: true), TestFixtures.chime]

        h.system.notify(102, kAudioProcessPropertyIsRunning)

        #expect(await eventually { mixer.apps.first?.isPlaying == true })
    }

    // MARK: - Taps

    @Test func appsAtUnityOnTheDefaultOutputAreNeverTapped() {
        let h = MixerHarness()
        h.start()
        #expect(h.system.taps.isEmpty)
    }

    @Test func turningAnAppDownTapsItOnTheDefaultOutput() throws {
        let h = MixerHarness()
        h.start().setVolume(0.5, for: music)

        let tap = try #require(h.tap())
        #expect(tap.processes == [101, 102])
        #expect(tap.outputUID == "speakers")
        #expect(tap.outputID == TestFixtures.speakers.id)
        #expect(tap.gain == 0.25)
        #expect(h.system.liveTaps.count == 1)
    }

    @Test func savedLevelsAreAppliedAtLaunch() throws {
        let h = MixerHarness()
        try h.save(levels: [music: AppLevel(volume: 0.5)])
        h.start()
        #expect(h.tap()?.gain == 0.25)
    }

    @Test func adjustingATappedAppUpdatesItsGainInPlace() throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        let tap = try #require(h.tap())

        mixer.setVolume(0.8, for: music)
        #expect(abs(tap.gain - 0.64) < 1e-6)

        mixer.toggleMute(for: music)
        #expect(tap.gain == 0)

        #expect(h.system.taps.count == 1)
        #expect(!tap.isDestroyed)
    }

    @Test func returningToUnityHoldsTheTapBrieflyThenTearsItDown() async throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        let tap = try #require(h.tap())

        mixer.setVolume(1, for: music)

        #expect(tap.gain == 1)
        #expect(!tap.isDestroyed)
        #expect(await eventually { h.delay.pending == [.seconds(1)] })

        h.delay.fireAll()
        #expect(await eventually { tap.isDestroyed })
        #expect(h.system.liveTaps.isEmpty)
    }

    @Test func movingAwayFromUnityDuringTheHoldKeepsTheTap() async throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        let tap = try #require(h.tap())
        mixer.setVolume(1, for: music)
        #expect(await eventually { h.delay.pending.count == 1 })

        mixer.setVolume(0.7, for: music)

        #expect(await eventually { h.delay.pending.isEmpty }, "the teardown was cancelled")
        await settle()
        #expect(!tap.isDestroyed)
        #expect(abs(tap.gain - 0.49) < 1e-6)
        #expect(h.system.taps.count == 1)
    }

    @Test func draggingAroundUnitySchedulesOneTeardown() async {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)

        for _ in 0..<3 { mixer.setVolume(1, for: music) }

        #expect(await eventually { h.delay.pending.count == 1 })
        await settle()
        #expect(h.delay.history == [.seconds(1)])
    }

    @Test func reroutingDuringTheHoldCancelsTheTeardown() async throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        let tap = try #require(h.tap())
        mixer.setVolume(1, for: music)
        #expect(await eventually { h.delay.pending.count == 1 })

        mixer.setRoute(uid: "airpods", for: music)

        #expect(await eventually { h.delay.pending.isEmpty })
        let rerouted = try #require(h.tap())
        #expect(rerouted.outputUID == "airpods")
        #expect(tap.isDestroyed)
        await settle()
        #expect(!rerouted.isDestroyed)
    }

    @Test func routingToTheCurrentDefaultDeviceIsNotARerouting() {
        let h = MixerHarness()
        let mixer = h.start()

        mixer.setRoute(uid: "speakers", for: music)

        #expect(mixer.route(for: music)?.uid == "speakers")
        #expect(h.system.taps.isEmpty, "already playing there at full volume")
    }

    @Test func routingTapsAnAppEvenAtFullVolume() throws {
        let h = MixerHarness()
        h.start().setRoute(uid: "airpods", for: music)

        let tap = try #require(h.tap())
        #expect(tap.outputUID == "airpods")
        #expect(tap.gain == 1)
    }

    @Test func unroutingAnAppAtFullVolumeDropsItsTapImmediately() throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setRoute(uid: "airpods", for: music)
        let tap = try #require(h.tap())

        mixer.setRoute(uid: nil, for: music)

        #expect(tap.isDestroyed)
        #expect(h.delay.history.isEmpty)
    }

    @Test func reroutingRebuildsMakeBeforeBreak() throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)

        mixer.setRoute(uid: "airpods", for: music)

        #expect(h.system.events == [
            "create \(music)@speakers",
            "create \(music)@airpods",
            "destroy \(music)@speakers",
        ])
        #expect(h.tap()?.gain == 0.25)
    }

    @Test func defaultOutputChangeMovesTaps() throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)

        h.system.defaultDevice = TestFixtures.airPods
        h.system.notify(.system, kAudioHardwarePropertyDefaultOutputDevice)

        #expect(mixer.defaultOutput == TestFixtures.airPods)
        #expect(h.tap()?.outputUID == "airpods")
        #expect(h.system.liveTaps.count == 1)
    }

    @Test func routedAppFallsBackWhenItsDeviceDisconnectsAndReturnsWithIt() {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        mixer.setRoute(uid: "airpods", for: music)

        h.system.devices = [TestFixtures.speakers]
        h.system.notify(.system, kAudioHardwarePropertyDevices)
        #expect(h.tap()?.outputUID == "speakers")

        h.system.devices = [TestFixtures.speakers, TestFixtures.airPods]
        h.system.notify(.system, kAudioHardwarePropertyDevices)
        #expect(h.tap()?.outputUID == "airpods")
        #expect(h.system.liveTaps.count == 1)
    }

    @Test func routedAppAtFullVolumeIsUntappedWhileItsDeviceIsGone() {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setRoute(uid: "airpods", for: music)

        h.system.devices = [TestFixtures.speakers]
        h.system.notify(.system, kAudioHardwarePropertyDevices)
        #expect(h.system.liveTaps.isEmpty)

        h.system.devices = [TestFixtures.speakers, TestFixtures.airPods]
        h.system.notify(.system, kAudioHardwarePropertyDevices)
        #expect(h.tap()?.outputUID == "airpods")
    }

    @Test func noTapWithoutAnOutputDevice() {
        let h = MixerHarness()
        h.system.devices = []
        h.system.defaultDevice = nil
        h.start().setVolume(0.5, for: music)
        #expect(h.system.taps.isEmpty)
    }

    @Test func appsThatQuitLoseTheirTapButKeepTheirLevel() throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        let tap = try #require(h.tap())

        h.system.apps = [TestFixtures.chime]
        mixer.refresh()

        #expect(tap.isDestroyed)
        #expect(mixer.level(for: music).volume == 0.5)

        h.system.apps = [TestFixtures.music, TestFixtures.chime]
        mixer.refresh()
        #expect(h.tap()?.gain == 0.25)
    }

    @Test func newHelperProcessRebuildsTheTap() throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        let tap = try #require(h.tap())

        h.system.apps = [TestFixtures.app(music, processes: [101, 102, 103]), TestFixtures.chime]
        mixer.refresh()

        #expect(tap.isDestroyed)
        #expect(h.tap()?.processes == [101, 102, 103])
    }

    @Test func exitedHelpersAreLeftOutOfTheTap() throws {
        let h = MixerHarness()
        h.system.deadProcesses = [102]
        let mixer = h.start()

        mixer.setVolume(0.5, for: music)
        #expect(h.tap()?.processes == [101])

        // Same scan result again: the dead helper is still filtered, so the tap isn't rebuilt.
        mixer.refresh()
        #expect(h.system.taps.count == 1)
    }

    @Test func appWithOnlyExitedProcessesIsNotTapped() {
        let h = MixerHarness()
        h.system.deadProcesses = [101, 102]
        h.start().setVolume(0.5, for: music)

        #expect(h.system.taps.isEmpty)
        #expect(h.delay.history.isEmpty, "nothing to retry")
    }

    // MARK: - Permission

    @Test func neverTapsWithoutPermission() {
        let h = MixerHarness()
        h.tcc.status = .denied
        h.start().setVolume(0.5, for: music)
        #expect(h.system.taps.isEmpty)
    }

    @Test func grantingPermissionAppliesSavedLevels() async throws {
        let h = MixerHarness()
        try h.save(levels: [music: AppLevel(volume: 0.5)])
        h.tcc.status = .notDetermined
        h.start()
        #expect(h.system.taps.isEmpty)

        let completion = try #require(h.tcc.completion)
        completion(true)

        #expect(await eventually { h.tap() != nil })
        #expect(h.tap()?.gain == 0.25)
    }

    @Test func revokingPermissionRemovesTaps() throws {
        let h = MixerHarness()
        h.start().setVolume(0.5, for: music)
        let tap = try #require(h.tap())

        h.tcc.status = .denied
        h.permission.refresh()

        #expect(tap.isDestroyed)

        h.tcc.status = .authorized
        h.permission.refresh()
        #expect(h.tap() != nil)
    }

    // MARK: - Failures and retries

    @Test func failedTapReportsAnErrorAndRetriesWithBackoff() async {
        let h = MixerHarness()
        let mixer = h.start()
        h.system.tapFailures = .max

        mixer.setVolume(0.5, for: music)
        #expect(mixer.lastError == "Music: Couldn't tap Music (OSStatus -1)")

        let expected: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4), .seconds(8)]
        for (attempt, delay) in expected.enumerated() {
            #expect(await eventually { h.delay.pending == [delay] }, "attempt \(attempt + 1)")
            h.delay.fireAll()
        }
        #expect(await eventually { h.system.events.count == 6 })
        await settle()
        #expect(h.delay.pending.isEmpty, "gives up after five retries")
        #expect(h.delay.history == expected)
        #expect(h.system.taps.isEmpty)
    }

    @Test func retrySucceedsAndClearsTheError() async throws {
        let h = MixerHarness()
        let mixer = h.start()
        h.system.tapFailures = 1

        mixer.setVolume(0.5, for: music)
        #expect(mixer.lastError != nil)
        #expect(await eventually { h.delay.pending.count == 1 })

        h.delay.fireAll()

        #expect(await eventually { h.tap() != nil })
        #expect(mixer.lastError == nil)
    }

    @Test func failedRebuildKeepsTheOldTap() async throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        let tap = try #require(h.tap())

        h.system.tapFailures = 1
        mixer.setRoute(uid: "airpods", for: music)

        #expect(!tap.isDestroyed, "the app stays at its level instead of jumping to full volume")
        #expect(mixer.lastError != nil)
        #expect(await eventually { h.delay.pending.count == 1 })

        h.delay.fireAll()
        #expect(await eventually { h.tap()?.outputUID == "airpods" })
        #expect(tap.isDestroyed)
        #expect(mixer.lastError == nil)
    }

    /// The one test on the real clock: without an injected delay, the first retry really waits half a second.
    @Test func defaultDelayIsRealTime() async {
        let h = MixerHarness()
        let mixer = Mixer(system: h.system, defaults: h.defaults, permission: h.permission)
        mixer.start()
        h.system.tapFailures = 1
        let start = ContinuousClock.now

        mixer.setVolume(0.5, for: music)
        #expect(h.tap() == nil)

        #expect(await eventually { h.tap() != nil })
        #expect(ContinuousClock.now - start >= .milliseconds(500))
        mixer.shutdown()
    }

    @Test func successResetsTheBackoff() async throws {
        let h = MixerHarness()
        let mixer = h.start()
        h.system.tapFailures = 1
        mixer.setVolume(0.5, for: music)
        #expect(await eventually { h.delay.pending.count == 1 })
        mixer.setVolume(0.4, for: music) // succeeds directly, cancelling the retry
        #expect(h.tap() != nil)
        #expect(await eventually { h.delay.pending.isEmpty })

        h.system.tapFailures = 1
        mixer.setRoute(uid: "airpods", for: music)
        #expect(await eventually { h.delay.pending == [.milliseconds(500)] }, "back to the first backoff step")
    }

    // MARK: - Sample rates

    @Test func sampleRateChangeRebuildsTapsOnThatDevice() throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        mixer.setRoute(uid: "airpods", for: chime)
        let musicTap = try #require(h.tap(music))
        let chimeTap = try #require(h.tap(chime))

        h.system.sampleRates[TestFixtures.speakers.id] = 44_100
        h.system.notify(TestFixtures.speakers.id, kAudioDevicePropertyNominalSampleRate)

        #expect(musicTap.isDestroyed)
        #expect(h.tap(music)?.outputUID == "speakers")
        #expect(!chimeTap.isDestroyed)
    }

    @Test func unchangedSampleRateLeavesTapsAlone() throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        let tap = try #require(h.tap())

        h.system.notify(TestFixtures.speakers.id, kAudioDevicePropertyNominalSampleRate)
        h.system.sampleRates[TestFixtures.speakers.id] = nil
        h.system.notify(TestFixtures.speakers.id, kAudioDevicePropertyNominalSampleRate)

        #expect(!tap.isDestroyed)
        #expect(h.system.taps.count == 1)
    }

    @Test func sampleRateListenersFollowTheDeviceList() {
        let h = MixerHarness()
        h.start()
        let rate = kAudioDevicePropertyNominalSampleRate
        #expect(h.system.listenerCount(on: TestFixtures.speakers.id, rate) == 1)
        #expect(h.system.listenerCount(on: TestFixtures.airPods.id, rate) == 1)

        h.system.devices = [TestFixtures.speakers]
        h.system.notify(.system, kAudioHardwarePropertyDevices)
        #expect(h.system.listenerCount(on: TestFixtures.airPods.id, rate) == 0)
        #expect(h.system.registrationCount(on: TestFixtures.speakers.id, rate) == 1, "existing listeners are reused")

        // The default device is watched even if it isn't offered in the picker.
        h.system.defaultDevice = TestFixtures.display
        h.system.sampleRates[TestFixtures.display.id] = 48_000
        h.system.notify(.system, kAudioHardwarePropertyDefaultOutputDevice)
        #expect(h.system.listenerCount(on: TestFixtures.display.id, rate) == 1)
    }

    @Test func reconnectedDeviceIsWatchedAgainWithItsCurrentRate() throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setRoute(uid: "airpods", for: music)
        h.system.devices = [TestFixtures.speakers]
        h.system.notify(.system, kAudioHardwarePropertyDevices)

        // AirPods come back in the call profile: the new rate is the baseline, not a change.
        h.system.sampleRates[TestFixtures.airPods.id] = 24_000
        h.system.devices = [TestFixtures.speakers, TestFixtures.airPods]
        h.system.notify(.system, kAudioHardwarePropertyDevices)
        let tap = try #require(h.tap())
        h.system.notify(TestFixtures.airPods.id, kAudioDevicePropertyNominalSampleRate)

        #expect(!tap.isDestroyed)
    }

    // MARK: - Reset and shutdown

    @Test func resetAllClearsEverything() async throws {
        let h = MixerHarness()
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        mixer.setRoute(uid: "airpods", for: chime)
        let musicTap = try #require(h.tap(music))
        let chimeTap = try #require(h.tap(chime))
        let scans = h.system.scanCount

        mixer.resetAll()

        #expect(mixer.levels.isEmpty)
        #expect(mixer.routes.isEmpty)
        #expect(!mixer.hasChanges)
        #expect(try h.savedLevels().isEmpty)
        #expect(try h.savedRoutes().isEmpty)
        #expect(h.system.scanCount == scans + 1)
        #expect(chimeTap.isDestroyed, "a tap on another device goes right away")
        #expect(musicTap.gain == 1)
        #expect(mixer.apps.map(\.id) == [music])

        #expect(await eventually { h.delay.pending.count == 1 })
        h.delay.fireAll()
        #expect(await eventually { musicTap.isDestroyed })
    }

    @Test func shutdownTearsDownTapsAndCancelsPendingWork() async throws {
        let h = MixerHarness()
        h.system.apps.append(TestFixtures.app("com.example.Podcasts", processes: [301]))
        let mixer = h.start()
        mixer.setVolume(0.5, for: music)
        mixer.setRoute(uid: "airpods", for: chime)
        mixer.setVolume(0.5, for: "com.example.Podcasts")
        mixer.setVolume(1, for: "com.example.Podcasts") // pending teardown
        h.system.tapFailures = 1
        mixer.setRoute(uid: "airpods", for: music) // pending retry, old tap kept
        #expect(await eventually { h.delay.pending.count == 2 })

        mixer.shutdown()

        #expect(h.system.liveTaps.isEmpty)
        #expect(h.system.taps.allSatisfy { $0.destroyCount == 1 })
        #expect(await eventually { h.delay.pending.isEmpty })
        await settle()
        #expect(h.system.liveTaps.isEmpty, "cancelled retries don't bring taps back")
    }
}
