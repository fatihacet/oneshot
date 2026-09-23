import Foundation
import OneShotCore

struct BackgroundPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var style: BackgroundDesign
}

/// Saved background presets and the last used style, kept in UserDefaults.
@MainActor
final class BackgroundPresetStore: ObservableObject {
    static let shared = BackgroundPresetStore()

    @Published private(set) var presets: [BackgroundPreset] = []

    private let presetsKey = "backgroundPresets"
    private let lastStyleKey = "backgroundLastStyle"

    private init() {
        if let data = UserDefaults.standard.data(forKey: presetsKey),
           let presets = try? JSONDecoder().decode([BackgroundPreset].self, from: data) {
            self.presets = presets
        }
    }

    var lastStyle: BackgroundDesign {
        get {
            guard let data = UserDefaults.standard.data(forKey: lastStyleKey),
                  let style = try? JSONDecoder().decode(BackgroundDesign.self, from: data) else { return BackgroundDesign() }
            return style
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: lastStyleKey) }
    }

    func add(name: String, style: BackgroundDesign) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        presets.append(BackgroundPreset(name: trimmed.isEmpty ? "Preset \(presets.count + 1)" : trimmed, style: style))
        save()
    }

    func remove(_ preset: BackgroundPreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(presets), forKey: presetsKey)
    }
}
