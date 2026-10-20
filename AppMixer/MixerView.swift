import SwiftUI

struct MixerView: View {
    let mixer: Mixer
    @AppStorage(RowStyle.storageKey) private var rowStyle: RowStyle = .compact
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("App Volume")
                    .font(.headline)
                Spacer()
                Button { showingSettings.toggle() } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Settings")
                .accessibilityLabel("Settings")
                .popover(isPresented: $showingSettings, arrowEdge: .bottom) {
                    SettingsView()
                }
            }

            if mixer.permission.status == .denied {
                PermissionNotice(permission: mixer.permission)
            }

            if mixer.apps.isEmpty {
                Text("No apps are using audio")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            } else {
                VStack(alignment: .leading, spacing: rowStyle == .compact ? 6 : 12) {
                    ForEach(mixer.apps) { app in
                        AppRow(app: app, mixer: mixer, style: rowStyle)
                    }
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
    let style: RowStyle

    var body: some View {
        Group {
            switch style {
            case .compact:
                HStack(spacing: 8) {
                    icon(size: 18)
                        .help(app.name)
                    controls
                }
            case .standard:
                HStack(spacing: 10) {
                    icon(size: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                            .lineLimit(1)
                        controls
                    }
                }
            }
        }
        .opacity(app.isPlaying ? 1 : 0.6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(app.name)
    }

    private func icon(size: CGFloat) -> some View {
        Image(nsImage: app.icon)
            .resizable()
            .frame(width: size, height: size)
    }

    private var controls: some View {
        let level = mixer.level(for: app.id)
        let silent = level.muted || level.volume == 0

        return HStack(spacing: 6) {
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
