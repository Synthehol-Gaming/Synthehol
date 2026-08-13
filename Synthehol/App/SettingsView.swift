import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    private var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil // follow macOS
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    static let storageKey = "appearance"

    /// Applies the stored preference app-wide (windows, sheets, menus).
    static func applyStored() {
        let raw = UserDefaults.standard.string(forKey: storageKey) ?? ""
        NSApp.appearance = (AppAppearance(rawValue: raw) ?? .system).nsAppearance
    }
}

struct SettingsView: View {
    @AppStorage(AppAppearance.storageKey) private var appearance = AppAppearance.system.rawValue

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppAppearance.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text("System follows your macOS appearance automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 360)
        .onChange(of: appearance) {
            AppAppearance.applyStored()
        }
    }
}
