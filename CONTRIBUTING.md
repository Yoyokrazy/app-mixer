# Contributing

## Setup

Needs macOS 15 or later, Xcode 26 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). The Xcode project is generated from `project.yml` and isn't checked in.

```sh
make run        # generate the project, build Release, and launch
make install    # same, but copy to /Applications first
make project    # just generate AppMixer.xcodeproj to open in Xcode
```

`XCODEBUILD_FLAGS` is passed through to `xcodebuild` by every target.

### Signing

Builds are ad-hoc signed, so they work on any Mac. The catch: macOS treats every rebuild as a new app and asks for System Audio Recording again. To keep the permission across rebuilds, sign with your Apple Development certificate by putting your team ID in a gitignored `local.mk` (or exporting `DEVELOPMENT_TEAM`):

```sh
echo 'DEVELOPMENT_TEAM := <your team ID>' > local.mk
```

The test targets are always ad-hoc signed, so `make test` and `make snapshots` never need a certificate.

## Unit tests

```sh
make test       # unit tests with code coverage, then a per-file coverage summary
```

`AppMixerTests` ([Swift Testing](https://developer.apple.com/documentation/testing)) compiles the app's sources instead of launching App Mixer, so the tests need no audio devices, permissions, or GUI session, and never touch App Mixer's saved settings. `Mixer`'s Core Audio side effects, permission, and timers are injected, so its routing, persistence, and tap decisions run against fakes. `TapRenderer` runs on synthetic buffers, and `scripts/next-version.sh` runs against throwaway git repos.

Creating real taps can't run in CI. Opt-in integration tests do it on a Mac with an output device: `TEST_RUNNER_APP_MIXER_INTEGRATION=1 make test`. They tap only the test process, and skip instead of prompting unless whatever launched them (Terminal, Xcode, …) already has System Audio Recording.

## Snapshot tests

```sh
make snapshots                     # verify; mismatches write actual/diff/reference PNGs to build/snapshot-failures
make record-snapshots              # re-record this Mac's references after an intended UI change
make adopt-ci-snapshots RUN=<id>   # take the CI runner's references from a failed Snapshots run
```

The popover and settings flyout are rendered from fixed fixtures (`AppMixer/Fixtures.swift`: fake apps, icons, and devices) in light and dark at 2x, and compared to `AppMixerSnapshotTests/__Snapshots__/<environment>`. The same fixtures feed the SwiftUI previews.

- **Per-toolchain references.** Text layout depends on the Xcode SDK, so references are kept per macOS + Xcode major version, e.g. `macos26-xcode27` (a dev Mac) and `macos26-xcode26` (CI). A toolchain without references records them and fails, so they get reviewed before being committed.
- **Tolerance.** A pixel counts as changed if a channel moves by more than 8/255, and a test fails when more than 20 pixels change. That absorbs Apple silicon vs. Intel rounding but still catches a single changed character.
- **Inactive style.** Controls render as they do in an inactive window (no accent fill on sliders), since making the test window key would steal focus.
- **CI.** The **Snapshots** workflow runs on `macos-26-intel`. On failure it uploads a `snapshot-failures` artifact and also prints the renders into the log.
- **After an intended UI change,** run `make record-snapshots` and push. When CI fails on the same change, review its renders and run `make adopt-ci-snapshots RUN=<run id>` (`gh run list -w Snapshots`). Commit both sets.

## Releases

Every merge to `main` runs the **Release** workflow, which builds a universal, ad-hoc signed app and publishes `AppMixer.zip` to a new `v<version>` tag and release.

- **Use [Conventional Commits](https://www.conventionalcommits.org); they decide the version** (`scripts/next-version.sh`). A breaking change bumps major, `feat` bumps minor, anything else bumps patch. If everything since the last release is `docs`, `test`, `ci`, `chore`, or `style`, nothing is released.
- **Bursts of merges become one release.** Each merge restarts a 10-minute quiet period (`RELEASE_DEBOUNCE_MINUTES` repo variable), and only the newest commit on `main` is released. Publishing is serialized and never cancelled mid-flight.
- **Manual release:** `gh workflow run release.yml`, optionally with `-f version=1.2.3`. Automatic releases run on `macos-26-intel` unless the `RELEASE_RUNNER` repo variable says otherwise.
