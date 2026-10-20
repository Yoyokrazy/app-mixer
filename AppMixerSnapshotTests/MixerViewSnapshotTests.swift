import SwiftUI
import Testing

/// Visual regression tests for the popover and the settings flyout, rendered from `MixerFixture`s.
/// References live in `__Snapshots__`; re-record them with `make record-snapshots`.
@MainActor
@Suite(.serialized)
struct MixerViewSnapshotTests {
    /// Untouched, routed (tinted icon, "→ AirPods Pro"), muted, and disconnected-route rows; reset enabled.
    @Test(arguments: RowStyle.allCases, SnapshotAppearance.allCases)
    func mixed(style: RowStyle, appearance: SnapshotAppearance) {
        snapshot(.mixed, style: style, appearance: appearance)
    }

    /// Nothing saved, so reset is disabled.
    @Test(arguments: SnapshotAppearance.allCases)
    func unchanged(appearance: SnapshotAppearance) {
        snapshot(.unchanged, style: .compact, appearance: appearance)
    }

    @Test(arguments: SnapshotAppearance.allCases)
    func empty(appearance: SnapshotAppearance) {
        snapshot(.empty, style: .compact, appearance: appearance)
    }

    @Test(arguments: SnapshotAppearance.allCases)
    func permissionDenied(appearance: SnapshotAppearance) {
        snapshot(.permissionDenied, style: .standard, appearance: appearance)
    }

    @Test(arguments: SnapshotAppearance.allCases)
    func error(appearance: SnapshotAppearance) {
        snapshot(.error, style: .compact, appearance: appearance)
    }

    @Test(arguments: RowStyle.allCases, SnapshotAppearance.allCases)
    func settings(style: RowStyle, appearance: SnapshotAppearance) {
        assertSnapshot(of: SettingsView().fixtureRowStyle(style), named: "settings-\(style.rawValue)", appearance: appearance)
    }

    private func snapshot(
        _ fixture: MixerFixture,
        style: RowStyle,
        appearance: SnapshotAppearance,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        assertSnapshot(
            of: MixerView(mixer: fixture.makeMixer()).fixtureRowStyle(style),
            named: "\(fixture.rawValue)-\(style.rawValue)",
            appearance: appearance,
            sourceLocation: sourceLocation
        )
    }
}
