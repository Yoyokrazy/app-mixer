import SwiftUI

struct MixerView: View {
    let mixer: Mixer
    @AppStorage(RowStyle.storageKey) private var rowStyle: RowStyle = .compact
    @State private var showingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 2) {
                Text("App Volume")
                    .font(.headline)
                Spacer()
                Button { mixer.resetAll() } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .modifier(HoverHighlight())
                }
                .buttonStyle(.plain)
                .disabled(!mixer.hasChanges)
                .help("Reset all apps to 100% on the system output")
                .accessibilityLabel("Reset")
                Button { showingSettings.toggle() } label: {
                    Image(systemName: "gearshape")
                        .modifier(HoverHighlight())
                }
                .buttonStyle(.plain)
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
                        HStack(spacing: 4) {
                            Text(app.name)
                                .lineLimit(1)
                            if let route = mixer.route(for: app.id) {
                                let connected = mixer.output(for: app.id)?.uid == route.uid
                                Text("→ \(route.name)\(connected ? "" : " (disconnected)")")
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        controls
                    }
                }
            }
        }
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

            OutputPicker(app: app, mixer: mixer)
        }
    }
}

/// Per-app output device. The icon is tinted when the app is routed somewhere specific.
private struct OutputPicker: View {
    let app: AudioApp
    let mixer: Mixer

    var body: some View {
        let route = mixer.route(for: app.id)
        let output = mixer.output(for: app.id)
        let isRouted = route != nil && output?.uid == route?.uid
        let defaultName = mixer.defaultOutput?.name ?? "None"

        Menu {
            Picker("Output", selection: Binding(get: { route?.uid }, set: { mixer.setRoute(uid: $0, for: app.id) })) {
                Text("System Default (\(defaultName))").tag(String?.none)
                Divider()
                ForEach(mixer.outputDevices, id: \.uid) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
                if let route, !mixer.outputDevices.contains(where: { $0.uid == route.uid }) {
                    Text("\(route.name) (disconnected)").tag(Optional(route.uid))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: output?.symbolName ?? "speaker.slash")
                .modifier(HoverHighlight(isActive: isRouted))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText(route: route, output: output, defaultName: defaultName))
        .accessibilityLabel("Output for \(app.name)")
    }

    private func helpText(route: Route?, output: OutputDevice?, defaultName: String) -> String {
        guard let route else { return "Output: System Default (\(defaultName))" }
        if output?.uid == route.uid { return "Output: \(route.name)" }
        return "Output: \(route.name) is disconnected, using \(defaultName)"
    }
}

/// Hover feedback for the small icon buttons: a rounded highlight and a brighter icon. `isActive` keeps the
/// icon tinted (e.g. a routed output) regardless of hover. Disabled buttons don't react.
private struct HoverHighlight: ViewModifier {
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        let highlighted = isHovering && isEnabled
        content
            .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(highlighted ? .primary : .secondary))
            .frame(width: 24, height: 20)
            .background(.primary.opacity(highlighted ? 0.15 : 0), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(RoundedRectangle(cornerRadius: 5))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: highlighted)
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
