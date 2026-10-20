import Foundation
import Testing

@Suite("CapturePermission")
@MainActor
struct CapturePermissionTests {
    @Test func startsUndetermined() {
        let tcc = FakeTCC()
        #expect(CapturePermission(access: tcc.access).status == .notDetermined)
    }

    @Test(arguments: [CapturePermission.Status.authorized, .denied, .notDetermined])
    func refreshReadsThePreflightAnswer(status: CapturePermission.Status) {
        let tcc = FakeTCC()
        tcc.status = status
        let permission = CapturePermission(access: tcc.access)
        permission.refresh()
        #expect(permission.status == status)
    }

    @Test func notifiesOnlyWhenTheStatusChanges() {
        let tcc = FakeTCC()
        let permission = CapturePermission(access: tcc.access)
        var changes = 0
        permission.onChange = { changes += 1 }

        tcc.status = .authorized
        permission.refresh()
        permission.refresh()
        #expect(changes == 1)

        tcc.status = .denied
        permission.refresh()
        #expect(changes == 2)
        #expect(permission.status == .denied)
    }

    @Test(arguments: [CapturePermission.Status.authorized, .denied])
    func doesNotAskWhenAlreadyDecided(status: CapturePermission.Status) {
        let tcc = FakeTCC()
        tcc.status = status
        let permission = CapturePermission(access: tcc.access)

        permission.requestIfNeeded()

        #expect(tcc.requestCount == 0)
        #expect(permission.status == status)
    }

    @Test(arguments: [true, false])
    func asksWhenUndeterminedAndAppliesTheAnswer(granted: Bool) async throws {
        let tcc = FakeTCC()
        tcc.status = .notDetermined
        let permission = CapturePermission(access: tcc.access)
        var changes = 0
        permission.onChange = { changes += 1 }

        permission.requestIfNeeded()
        #expect(tcc.requestCount == 1)
        #expect(permission.status == .notDetermined)

        // TCC answers on its own queue.
        let completion = try #require(tcc.completion)
        DispatchQueue.global().async { completion(granted) }

        let expected: CapturePermission.Status = granted ? .authorized : .denied
        #expect(await eventually { permission.status == expected })
        #expect(changes == 1)
    }

    @Test func pinnedStatusIgnoresTCC() {
        let tcc = FakeTCC()
        tcc.status = .authorized
        let permission = CapturePermission(access: tcc.access)
        var changes = 0
        permission.onChange = { changes += 1 }

        permission.pin(.denied)
        permission.refresh()
        permission.requestIfNeeded()

        #expect(permission.status == .denied)
        #expect(tcc.requestCount == 0)
        #expect(changes == 0, "pinning isn't a permission change")
    }

    @Test func tccSymbolsResolve() {
        // If these private symbols ever disappear, App Mixer silently assumes access; catch that here.
        #expect(CapturePermission.symbol("TCCAccessPreflight", as: UnsafeRawPointer.self) != nil)
        #expect(CapturePermission.symbol("TCCAccessRequest", as: UnsafeRawPointer.self) != nil)
        #expect(CapturePermission.symbol("NotARealTCCFunction", as: UnsafeRawPointer.self) == nil)
    }

    /// Preflight only reads the current answer; it never prompts.
    @Test func realPreflightAnswers() {
        let permission = CapturePermission()
        permission.refresh()
        #expect([.authorized, .denied, .notDetermined].contains(permission.status))
    }
}
