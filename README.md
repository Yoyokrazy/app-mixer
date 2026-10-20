# App Mixer

A tiny macOS menu bar app for per-app volume, with optional per-app output routing.

Click the menu bar icon to see every app that's using audio, each with its own volume slider and mute button. Apps that are open but silent (say, a browser paused on a video) are listed too, so you can set their level before they play. Levels are remembered per app and re-applied whenever the app is running.

Next to the title, **↺** resets every app to 100% on the system output device (clearing all saved levels and routes), and the **gear** opens a small settings flyout:

- **Layout**: *Compact* (default, one line per app, hover the icon for its name) or *Standard* (app name above each slider).
- **Advanced** (off by default): adds an output picker to each row so you can send an app to a specific device, e.g. Spotify to AirPods while everything else stays on the speakers. Routed apps get a tinted device icon (and "→ device" in Standard layout). If a routed device disconnects, the app falls back to the system output and returns when the device does. Routes are remembered while Advanced is off but not applied.

## How it works

Uses the Core Audio process-tap API (macOS 14.2+), the same approach as [FineTune](https://github.com/ronitsingh10/FineTune), minus everything except the mixer:

1. A **process tap** (`CATapDescription`, `.mutedWhenTapped`) mutes the app at the HAL and exposes its audio as a stream.
2. A **private aggregate device** pairs that stream with the app's output device: the system default, or its routed device in Advanced mode.
3. An **IOProc** copies tap → output, applying a smoothed gain (square-law slider taper, ~30 ms ramp).

Apps at 100% on the default device are never tapped, so App Mixer adds no latency or overhead until you turn something down or route it elsewhere. Once an app is changed, its tap stays up for as long as the app is a Core Audio client (its IO only runs while the app is actually playing), so short sounds like notifications start at the right level and on the right device. Taps and aggregates are private to the App Mixer process, so macOS tears them down and un-mutes every app if App Mixer quits or crashes.

Taps are rebuilt automatically when the default output device changes, when devices connect or disconnect, when a device's sample rate changes (e.g. AirPods switching to the call profile), or when an app gains or loses audio helper processes.

## Install

Download the latest release with the [GitHub CLI](https://cli.github.com) (no Xcode or XcodeGen needed):

```sh
gh release download -R Yoyokrazy/app-mixer -p AppMixer.zip -O /tmp/AppMixer.zip --clobber
osascript -e 'tell application id "com.yoyokrazy.AppMixer" to quit' 2>/dev/null
rm -rf /Applications/AppMixer.app && ditto -x -k /tmp/AppMixer.zip /Applications
open /Applications/AppMixer.app
```

The same commands upgrade an existing install. Requires macOS 15 or later (Apple silicon or Intel).

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

## Build from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make run       # generate project, build Release, launch
make install   # same, but copies to /Applications
make project   # just generate AppMixer.xcodeproj to open in Xcode
```

Local builds are signed with the "Apple Development" identity for team `K77TX49CTD` (see `project.yml`). That stable signature means the audio-capture permission survives rebuilds.

## Releasing

Run the **Release** workflow (Actions → Release → Run workflow, or `gh workflow run release.yml -f version=0.2.0`). It builds a universal app on a macOS runner, stamps the version, ad-hoc signs, and publishes `AppMixer.zip` to a new `v<version>` tag and release, with the commits since the previous tag as notes. If arm64 runners are backed up, pick `macos-26-intel` (`-f runner=macos-26-intel`).

## Limitations

- Changed apps play on App Mixer's chosen device (the system default unless routed in Advanced mode). An app that you've pointed at a different device itself (e.g. Zoom set to a headset) will move while it's turned down or routed.
- The first ~20–90 ms of an app's very first sound can play at full volume on its original device, before App Mixer sees the app's new audio process.
- Volume tops out at 100%; there's no boost.
- Permission status is read via the private TCC framework (as FineTune does), since there's no public API for it.
