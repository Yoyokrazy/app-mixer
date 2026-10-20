# App Mixer

A tiny macOS menu bar app that does one thing: per-app volume.

Click the menu bar icon to see every app that's playing audio, each with its own volume slider and mute button. Levels are remembered per app and re-applied when the app plays again.

The gear in the popover opens a small settings flyout with one option, **Layout**: *Compact* (default, one line per app, hover the icon for its name) or *Standard* (app name above each slider).

## How it works

Uses the Core Audio process-tap API (macOS 14.2+), the same approach as [FineTune](https://github.com/ronitsingh10/FineTune), minus everything except the mixer:

1. A **process tap** (`CATapDescription`, `.mutedWhenTapped`) mutes the app at the HAL and exposes its audio as a stream.
2. A **private aggregate device** pairs that stream with the current default output device.
3. An **IOProc** copies tap → output, applying a smoothed gain (square-law slider taper, ~30 ms ramp).

Apps at 100% are never tapped, so App Mixer adds no latency or overhead until you turn something down. Once an app is below 100% (or muted), its tap stays up for as long as the app is a Core Audio client, so short sounds like notifications start at the right level. Taps and aggregates are private to the App Mixer process, so macOS tears them down and un-mutes every app if App Mixer quits or crashes.

Taps are rebuilt automatically when the default output device changes, when its sample rate changes (e.g. AirPods switching to the call profile), or when an app gains or loses audio helper processes.

## Build & run

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make run       # generate project, build Release, launch
make install   # same, but copies to /Applications
make project   # just generate AppMixer.xcodeproj to open in Xcode
```

Signing uses the "Apple Development" identity for team `K77TX49CTD` (see `project.yml`). A stable signature matters: macOS ties the audio-capture permission to it, so ad-hoc builds would re-prompt after every rebuild.

On first launch macOS asks for **System Audio Recording** access. Without it App Mixer won't tap anything (a tap without permission just produces silence). If you denied it, re-enable it in System Settings → Privacy & Security → Screen & System Audio Recording.

To start at login, add App Mixer in System Settings → General → Login Items.

## Limitations

- Tapped audio always plays on the **system default output device**. An app that you've pointed at a different device itself (e.g. Zoom set to a headset) will move to the default device while its volume is below 100%.
- Volume tops out at 100%; there's no boost.
- Permission status is read via the private TCC framework (as FineTune does), since there's no public API for it.
