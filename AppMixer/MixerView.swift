import SwiftUI

struct MixerView: View {
    let mixer: Mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("App Volume")
                .font(.headline)

            if mixer.permission.status == .denied {
                PermissionNotice(permission: mixer.permission)
            }

            if mixer.apps.isEmpty {
                Text("No apps are playing audio")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            } else {
                ForEach(mixer.apps) { app in
                    AppRow(app: app, mixer: mixer)
                }
            }

            if let error = mixer.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Button("Quit App Mixer") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 300)
        .onAppear {
            mixer.permission.refresh()
            mixer.refresh()
        }
    }
}

private struct AppRow: View {
    let app: AudioApp
    let mixer: Mixer

    var body: some View {
        let level = mixer.level(for: app.id)
        let silent = level.muted || level.volume == 0

        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Button { mixer.toggleMute(for: app.id) } label: {
                        Image(systemName: silent ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 18)
                    }
                    .buttonStyle(.plain)
                    .help(level.muted ? "Unmute" : "Mute")

                    Slider(
                        value: Binding(get: { level.volume }, set: { mixer.setVolume($0, for: app.id) }),
                        in: 0...1
                    )
                    .controlSize(.small)
                    .opacity(level.muted ? 0.4 : 1)

                    Text("\(Int((level.volume * 100).rounded()))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .opacity(app.isPlaying ? 1 : 0.6)
    }
}

private struct PermissionNotice: View {
    let permission: CapturePermission

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("App Mixer needs System Audio Recording access to change app volumes.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") { permission.openSettings() }
                .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }
}
