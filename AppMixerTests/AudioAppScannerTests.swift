import AppKit
import AudioToolbox
import Testing

struct FakeRunningApp: RunningApp {
    var processIdentifier: pid_t
    var bundleIdentifier: String?
    var bundleURL: URL?
    var localizedName: String?
    var icon: NSImage?
    var activationPolicy: NSApplication.ActivationPolicy = .regular

    init(
        pid: pid_t,
        bundleID: String?,
        path: String?,
        name: String? = nil,
        icon: NSImage? = NSImage(),
        policy: NSApplication.ActivationPolicy = .regular
    ) {
        processIdentifier = pid
        bundleIdentifier = bundleID
        bundleURL = path.map { URL(fileURLWithPath: $0) }
        localizedName = name
        self.icon = icon
        activationPolicy = policy
    }
}

@Suite("AudioAppScanner")
@MainActor
struct AudioAppScannerTests {
    static let ownPID: pid_t = 500

    static let safari = FakeRunningApp(pid: 100, bundleID: "com.apple.Safari", path: "/Applications/Safari.app", name: "Safari")
    /// WebKit's GPU process is an XPC service, attributed to Safari only by responsibility.
    static let webKitGPU = FakeRunningApp(
        pid: 200,
        bundleID: "com.apple.WebKit.GPU",
        path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.GPU.xpc"
    )
    static let chrome = FakeRunningApp(pid: 300, bundleID: "com.google.Chrome", path: "/Applications/Google Chrome.app", name: "Google Chrome")
    /// Chrome's helpers are .apps nested inside Chrome and are children of the main process.
    static let chromeHelper = FakeRunningApp(
        pid: 301,
        bundleID: "com.google.Chrome.helper",
        path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app",
        name: "Google Chrome Helper"
    )
    static let agent = FakeRunningApp(pid: 600, bundleID: "com.example.bartender", path: "/Applications/Bartender.app", name: "bartender", policy: .accessory)
    static let zoom = FakeRunningApp(pid: 700, bundleID: "us.zoom.xos", path: "/Applications/zoom.us.app", name: "Zoom")
    static let ourselves = FakeRunningApp(pid: ownPID, bundleID: "com.yoyokrazy.AppMixer", path: "/Applications/AppMixer.app", name: "App Mixer")

    static let running = [safari, webKitGPU, chrome, chromeHelper, agent, zoom, ourselves]

    /// Process object → (pid, is playing).
    static let processes: [AudioObjectID: (pid: pid_t?, playing: Bool)] = [
        11: (200, true), // Safari's GPU process, listed before Safari itself
        10: (100, false),
        30: (300, false),
        31: (301, true),
        40: (400, false), // coreaudiod: no app
        50: (ownPID, true), // App Mixer itself
        51: (501, true), // one of App Mixer's own helpers
        60: (600, false),
        70: (700, false),
        80: (nil, true), // exited
        81: (0, true),
    ]

    static func responsible(_ pid: pid_t) -> pid_t? {
        [200: 100, 501: ownPID][pid]
    }

    static func parent(_ pid: pid_t) -> pid_t? {
        [301: 300, 400: 1, 100: 1, 300: 1, 200: 1, 501: 1, 600: 1, 700: 1][pid]
    }

    static func scan(_ objects: [AudioObjectID]? = nil, running: [FakeRunningApp] = running) -> [AudioApp] {
        AudioAppScanner.scan(
            processes: objects ?? Array(processes.keys),
            running: running,
            ownPID: ownPID,
            pid: { processes[$0]?.pid },
            isPlaying: { processes[$0]?.playing ?? false },
            responsiblePID: responsible,
            parentPID: parent
        )
    }

    // MARK: - Grouping

    @Test func groupsHelpersUnderTheirApp() {
        let apps = Self.scan()

        #expect(apps.map(\.id) == ["com.example.bartender", "com.google.Chrome", "com.apple.Safari", "us.zoom.xos"])
        let safari = apps.first { $0.id == "com.apple.Safari" }
        #expect(safari?.processes == [10, 11])
        #expect(safari?.name == "Safari")
        let chrome = apps.first { $0.id == "com.google.Chrome" }
        #expect(chrome?.processes == [30, 31])
    }

    @Test func sortsAppsByNameIgnoringCase() {
        let names = Self.scan().map(\.name)
        #expect(names == ["bartender", "Google Chrome", "Safari", "Zoom"])
    }

    @Test func appIsPlayingWhenAnyProcessIs() {
        let apps = Dictionary(uniqueKeysWithValues: Self.scan().map { ($0.id, $0) })
        #expect(apps["com.apple.Safari"]?.isPlaying == true) // only the GPU process plays
        #expect(apps["com.google.Chrome"]?.isPlaying == true)
        #expect(apps["us.zoom.xos"]?.isPlaying == false)
    }

    @Test func regularAppsAreDockApps() {
        let apps = Dictionary(uniqueKeysWithValues: Self.scan().map { ($0.id, $0) })
        #expect(apps["com.apple.Safari"]?.isRegularApp == true)
        #expect(apps["com.example.bartender"]?.isRegularApp == false)
    }

    @Test func skipsItselfItsHelpersDaemonsAndExitedProcesses() {
        let processes = Set(Self.scan().flatMap(\.processes))
        #expect(!processes.contains(40))
        #expect(!processes.contains(50))
        #expect(!processes.contains(51))
        #expect(!processes.contains(80))
        #expect(!processes.contains(81))
        #expect(!Self.scan().contains { $0.id == "com.yoyokrazy.AppMixer" })
    }

    @Test func groupingDoesNotDependOnProcessOrder() {
        let objects = Array(Self.processes.keys)
        #expect(Self.scan(objects.sorted()) == Self.scan(objects.sorted(by: >)))
    }

    @Test func fallsBackToBundleIDAndGenericIcon() throws {
        let unnamed = FakeRunningApp(pid: 900, bundleID: "com.example.unnamed", path: "/Applications/Unnamed.app", name: nil, icon: nil)
        let apps = AudioAppScanner.scan(
            processes: [90],
            running: [unnamed],
            ownPID: Self.ownPID,
            pid: { _ in 900 },
            isPlaying: { _ in false },
            responsiblePID: { _ in nil },
            parentPID: { _ in nil }
        )
        let app = try #require(apps.first)
        #expect(app.name == "com.example.unnamed")
        #expect(app.icon.isValid)
    }

    @Test func skipsAppsWithoutABundleID() {
        let anonymous = FakeRunningApp(pid: 900, bundleID: nil, path: "/Applications/Anonymous.app")
        let apps = AudioAppScanner.scan(
            processes: [90],
            running: [anonymous],
            ownPID: Self.ownPID,
            pid: { _ in 900 },
            isPlaying: { _ in true },
            responsiblePID: { _ in nil },
            parentPID: { _ in nil }
        )
        #expect(apps.isEmpty)
    }

    @Test func emptyProcessListMeansNoApps() {
        #expect(Self.scan([]).isEmpty)
    }

    @Test func duplicatePIDsKeepTheFirstApp() {
        let impostor = FakeRunningApp(pid: 100, bundleID: "com.example.impostor", path: "/Applications/Impostor.app")
        let apps = Self.scan([10], running: [Self.safari, impostor])
        #expect(apps.map(\.id) == ["com.apple.Safari"])
    }

    // MARK: - Owner resolution

    static func owner(of pid: pid_t, running: [FakeRunningApp], responsible: [pid_t: pid_t] = [:], parents: [pid_t: pid_t] = [:]) -> String? {
        let running = Dictionary(uniqueKeysWithValues: running.map { ($0.processIdentifier, $0) })
        return AudioAppScanner.owningApp(
            of: pid,
            running: running,
            responsiblePID: { responsible[$0] },
            parentPID: { parents[$0] }
        )?.bundleIdentifier
    }

    @Test func topLevelAppOwnsItself() {
        #expect(Self.owner(of: 100, running: [Self.safari]) == "com.apple.Safari")
    }

    @Test func nestedHelperAppIsNotAnOwner() {
        #expect(Self.owner(of: 301, running: [Self.chromeHelper]) == nil)
    }

    @Test func appWithoutABundleURLIsNotAnOwner() {
        let noURL = FakeRunningApp(pid: 100, bundleID: "com.example.nourl", path: nil)
        #expect(Self.owner(of: 100, running: [noURL]) == nil)
    }

    @Test func resolvesThroughTheResponsibleProcess() {
        #expect(Self.owner(of: 200, running: [Self.safari, Self.webKitGPU], responsible: [200: 100]) == "com.apple.Safari")
    }

    @Test func fallsBackToParentsWhenTheResponsibleProcessIsNotAnApp() {
        let owner = Self.owner(of: 301, running: [Self.chrome, Self.chromeHelper], responsible: [301: 999], parents: [301: 300])
        #expect(owner == "com.google.Chrome")
    }

    @Test func walksUpSeveralParents() {
        let owner = Self.owner(of: 3, running: [Self.chrome], parents: [3: 2, 2: 300])
        #expect(owner == "com.google.Chrome")
    }

    @Test func checksLaunchdButNeverWalksPastIt() {
        let launchd = FakeRunningApp(pid: 1, bundleID: "com.apple.launchd", path: "/sbin/launchd.app")
        let beyond = FakeRunningApp(pid: 900, bundleID: "com.example.beyond", path: "/Applications/Beyond.app")
        #expect(Self.owner(of: 400, running: [launchd], parents: [400: 1]) == "com.apple.launchd")
        #expect(Self.owner(of: 400, running: [beyond], parents: [400: 1, 1: 900]) == nil)
    }

    @Test func survivesParentCycles() {
        #expect(Self.owner(of: 800, running: [], parents: [800: 801, 801: 800]) == nil)
        #expect(Self.owner(of: 800, running: [], parents: [800: 800]) == nil)
    }

    @Test func unknownParentEndsTheWalk() {
        #expect(Self.owner(of: 800, running: [Self.safari]) == nil)
    }

    // MARK: - Real process lookups (read-only)

    @Test func parentOfThisProcess() {
        #expect(AudioAppScanner.parentPID(of: getpid()) == getppid())
    }

    @Test func parentOfAMissingProcess() {
        #expect(AudioAppScanner.parentPID(of: 99_999_999) == nil)
    }

    @Test func responsibleProcessIsAnotherProcessOrNil() {
        if let responsible = AudioAppScanner.responsiblePID(for: getpid()) {
            #expect(responsible > 0)
            #expect(responsible != getpid())
        }
        #expect(AudioAppScanner.responsiblePID(for: 99_999_999) == nil)
    }

    @Test func nsRunningApplicationConforms() {
        let current = NSRunningApplication.current as any RunningApp
        #expect(current.processIdentifier == getpid())
    }
}
