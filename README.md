# App Mixer

A tiny macOS menu bar app for per-app volume and output routing.

Click the menu bar icon to see every app that's using audio, each with its own volume slider, mute button, and output picker. Apps that are open but silent (say, a browser paused on a video) are listed too, so you can set them up before they play. Settings are remembered per app and re-applied whenever the app is running.

- **Output picker** (device icon at the end of each row): send an app to a specific device, e.g. Spotify to AirPods while everything else stays on the speakers, or leave it on *System Default* to follow Control Center. Routed apps get a tinted icon (and "→ device" in Standard layout). If a routed device disconnects, the app falls back to the system output and returns when the device does.
- **↺** next to the title resets every app to 100% on the system output device, clearing all saved levels and routes.
- **Gear** opens a small settings flyout with **Layout**: *Compact* (default, one line per app, hover the icon for its name) or *Standard* (app name above each slider).

## How it works

Uses the Core Audio process-tap API (macOS 14.2+), the same approach as [FineTune](https://github.com/ronitsingh10/FineTune), minus everything except the mixer:

1. A **process tap** (`CATapDescription`, `.mutedWhenTapped`) mutes the app at the HAL and exposes its audio as a stream.
2. A **private aggregate device** pairs that stream with the app's output device: the system default, or the device it's routed to.
3. An **IOProc** copies tap → output, applying a smoothed gain (square-law slider taper, ~30 ms ramp).

Apps at 100% on the default device are never tapped, so App Mixer adds no latency or overhead until you turn something down or route it elsewhere. Once an app is changed, its tap stays up for as long as the app is a Core Audio client (its IO only runs while the app is actually playing), so short sounds like notifications start at the right level and on the right device. Taps and aggregates are private to the App Mixer process, so macOS tears them down and un-mutes every app if App Mixer quits or crashes.

Taps are rebuilt automatically when the default output device changes, when devices connect or disconnect, when a device's sample rate changes (e.g. AirPods switching to the call profile), or when an app gains or loses audio helper processes.

## Install

Requires macOS 15 or later (Apple silicon or Intel). The repository is private, so you need read access (ask the owner to add you as a collaborator) and the [GitHub CLI](https://cli.github.com) signed in with `gh auth login`. No Xcode or XcodeGen needed:

```sh
gh release download -R Yoyokrazy/app-mixer -p AppMixer.zip -O /tmp/AppMixer.zip --clobber
osascript -e 'tell application id "com.yoyokrazy.AppMixer" to quit' 2>/dev/null
rm -rf /Applications/AppMixer.app && ditto -x -k /tmp/AppMixer.zip /Applications
open /Applications/AppMixer.app
```

The same commands upgrade an existing install. App Mixer has no Dock icon or window: look for the sliders icon in the menu bar, and quit it from the bottom of its popover. Quitting returns every app to its normal volume and output.

### First launch

- **Gatekeeper.** Release builds are ad-hoc signed and not notarized. Downloading with `gh` avoids Gatekeeper's quarantine. If you downloaded the zip in a browser instead, macOS will refuse to open it; run `xattr -dr com.apple.quarantine /Applications/AppMixer.app` (or use System Settings → Privacy & Security → Open Anyway).
- **System Audio Recording.** macOS asks for this permission on first launch. Without it App Mixer won't touch any app's audio (a tap without permission just produces silence) and the popover shows a button to the right settings page. If you denied it, re-enable it in System Settings → Privacy & Security → Screen & System Audio Recording.
- **Start at login.** Add App Mixer in System Settings → General → Login Items.

### Keeping the permission across upgrades (optional signing)

Because release builds are ad-hoc signed, macOS treats every new version as a different app and asks for System Audio Recording again. To avoid that, sign each install with a certificate of your own, using the same certificate every time, before launching it:

```sh
security find-identity -v -p codesigning   # list your signing identities
codesign --force --sign "Apple Development: Your Name (XXXXXXXXXX)" /Applications/AppMixer.app
```

Any code-signing identity works. If you don't have one, create a free self-signed certificate in Keychain Access → Certificate Assistant → Create a Certificate… (Identity Type: *Self-Signed Root*, Certificate Type: *Code Signing*) and use its name.

If the permission toggle gets out of sync after switching signatures (it's on in Settings but App Mixer still can't change volumes), reset it and relaunch to be asked again:

```sh
tccutil reset AudioCapture com.yoyokrazy.AppMixer
```

### Uninstall

```sh
osascript -e 'tell application id "com.yoyokrazy.AppMixer" to quit'
rm -rf /Applications/AppMixer.app
defaults delete com.yoyokrazy.AppMixer                  # saved levels, routes, and layout
tccutil reset AudioCapture com.yoyokrazy.AppMixer       # System Audio Recording permission
```

## Build from source

Requires macOS 15 or later, Xcode 26 or later (CI uses 26.6), and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
gh repo clone Yoyokrazy/app-mixer && cd app-mixer
make run       # generate project, build Release, launch
make install   # same, but copies to /Applications
make project   # just generate AppMixer.xcodeproj to open in Xcode
```

**Signing.** `make build`/`run`/`install` sign with the maintainer's "Apple Development" certificate (team `K77TX49CTD`, see `project.yml`), so on anyone else's Mac they fail at code signing. Override it with `XCODEBUILD_FLAGS`, which every `make` target passes to `xcodebuild`:

```sh
# Ad-hoc signature: works everywhere, but macOS asks for System Audio Recording again after each rebuild.
make run XCODEBUILD_FLAGS="CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM="

# Your own Apple Development certificate: a stable signature, so the permission survives rebuilds.
make run XCODEBUILD_FLAGS='CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=<your team ID>'
```

The test targets (below) are always ad-hoc signed, so `make test` and `make snapshots` need no certificate.

## Testing

```sh
make test      # unit tests with code coverage, then a per-file coverage summary
```

The `AppMixerTests` target ([Swift Testing](https://developer.apple.com/documentation/testing)) compiles the app's sources directly instead of launching App Mixer, so tests need no audio devices, permissions, or GUI session, and never touch App Mixer's saved settings. `Mixer`'s Core Audio side effects, permission, and timers are injectable, so its routing, persistence, and tap decisions run against fakes; `TapRenderer` runs on synthetic buffers; the views are rendered in each state (the snapshot tests below check how they look); `scripts/next-version.sh` runs against throwaway git repos. The **Tests** workflow runs this on every pull request and push to `main` and posts the coverage table to the job summary.

Creating real taps can't run in CI. Opt-in integration tests do that on a Mac with an output device: `TEST_RUNNER_APP_MIXER_INTEGRATION=1 make test`. They tap only the test process itself, and skip (rather than prompt) unless whatever launched them (Terminal, Xcode, ...) already has System Audio Recording.

## Visual testing

Snapshot tests render the popover and the settings flyout from fixed fixtures (fake apps, icons, and devices; nothing from your Mac) in light and dark at 2x, and compare them to the PNGs in `AppMixerSnapshotTests/__Snapshots__/<environment>`.

```sh
make snapshots                     # verify; mismatches write actual/diff/reference PNGs to build/snapshot-failures
make record-snapshots              # re-record this Mac's references after an intended UI change
make adopt-ci-snapshots RUN=<id>   # take the CI runner's references from a failed Snapshots run
```

- **Coverage:** compact and standard rows; routed (tinted icon, "→ device"), muted, and disconnected-route apps; reset enabled and disabled; empty state; permission notice; error text; the settings flyout.
- **Isolation:** the tests don't launch App Mixer, touch Core Audio, or read or write your settings. The test bundle compiles the app's sources and renders `Mixer`s seeded with `Mixer(fixtureApps:…)`. The same fixtures (`AppMixer/Fixtures.swift`) feed the SwiftUI previews.
- **One set of references per toolchain:** text layout depends on the Xcode SDK (Xcode 26 lays the popover out a few points shorter than Xcode 27), so references are kept per macOS + Xcode major version, e.g. `macos26-xcode27` (a dev Mac) and `macos26-xcode26` (CI). A toolchain without references records them and fails, so you can review and commit them.
- **Tolerance:** a pixel counts as changed only if a channel moves by more than 8/255, and a test fails once more than 20 pixels change. That absorbs Apple silicon vs. Intel rounding (at most 3–4/255) but still catches a single changed character.
- Controls render in their inactive-window style (e.g. no accent fill on sliders), since making the window key would steal focus from whatever you're doing.
- **CI:** the **Snapshots** workflow runs `make snapshots` on `macos-26-intel` for pull requests and pushes to `main`. When it fails, it uploads a `snapshot-failures` artifact (if artifact storage allows) and also prints the rendered images into the log.
- **After an intended UI change:** run `make record-snapshots` and push. When CI fails on the same change, review its renders and run `make adopt-ci-snapshots RUN=<run id>` (find the ID with `gh run list -w Snapshots`). Commit both sets.

## Releasing

Releases are automatic. Every merge to `main` triggers the **Release** workflow, which builds a universal app on a macOS runner, stamps the version, ad-hoc signs, and publishes `AppMixer.zip` to a new `v<version>` tag and release, with the commits since the previous tag as notes.

- **Version** comes from the [Conventional Commits](https://www.conventionalcommits.org) since the last tag (`scripts/next-version.sh`): a breaking change bumps major, `feat` bumps minor, anything else bumps patch. If everything since the last release is `docs`/`test`/`ci`/`chore`/`style`, nothing is released.
- **Bursts of merges become one release.** Each merge restarts a 10-minute quiet period (set the `RELEASE_DEBOUNCE_MINUTES` repo variable to change it), and only the newest commit on `main` is released. Publishing is serialized and never cancelled mid-flight, so two releases can't race or end up half-made.
- **Manual releases** still work: Actions → Release → Run workflow, or `gh workflow run release.yml` (optionally `-f version=1.2.3`, and `-f runner=macos-26-intel` if arm64 runners are backed up). Automatic releases use `macos-26-intel` unless the `RELEASE_RUNNER` repo variable says otherwise.

## Limitations

- Changed apps play on App Mixer's chosen device (the system default unless routed). An app that you've pointed at a different device itself (e.g. Zoom set to a headset) will move while it's turned down or routed.
- The first ~20–90 ms of an app's very first sound can play at full volume on its original device, before App Mixer sees the app's new audio process.
- Volume tops out at 100%; there's no boost.
- Permission status is read via the private TCC framework (as FineTune does), since there's no public API for it.
