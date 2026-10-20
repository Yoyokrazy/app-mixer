import SwiftUI

enum RowStyle: String, CaseIterable, Identifiable {
    case compact
    case standard

    static let storageKey = "rowStyle"

    var id: Self { self }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        }
    }
}

/// Flyout shown from the gear button; deliberately a popover rather than a Settings window.
struct SettingsView: View {
    @AppStorage(RowStyle.storageKey) private var rowStyle: RowStyle = .compact

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Layout")
                .font(.subheadline.weight(.semibold))

            Picker("Layout", selection: $rowStyle) {
                ForEach(RowStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(rowStyle == .compact ? "One line per app; hover an icon for its name." : "Shows each app's name above its slider.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 220)
    }
}
