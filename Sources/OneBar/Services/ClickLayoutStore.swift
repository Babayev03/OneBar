import Foundation
import Observation

struct ClickLayout: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var nodes: [ClickNode]
    var savedAt = Date()
}

/// Named point setups, on disk beside the clipboard history rather than in
/// `UserDefaults`: a layout holds arbitrarily many nodes and is the sort of
/// thing worth being able to find and back up as a file.
@MainActor
@Observable
final class ClickLayoutStore {
    static let shared = ClickLayoutStore()

    private let fileURL: URL
    private(set) var layouts: [ClickLayout] = []

    private init() {
        fileURL = ClipboardStore.shared.baseDirectory.appendingPathComponent("click-layouts.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ClickLayout].self, from: data) {
            layouts = decoded
        }
    }

    /// Saving under an existing name overwrites it, so re-saving a layout you
    /// just tweaked doesn't quietly leave two of them behind.
    func save(_ name: String, nodes: [ClickNode]) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !nodes.isEmpty else { return }

        if let index = layouts.firstIndex(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            layouts[index].nodes = nodes
            layouts[index].savedAt = Date()
        } else {
            layouts.append(ClickLayout(name: trimmed, nodes: nodes))
        }
        layouts.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        write()
    }

    func delete(_ id: UUID) {
        layouts.removeAll { $0.id == id }
        write()
    }

    func layout(_ id: UUID) -> ClickLayout? {
        layouts.first { $0.id == id }
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(layouts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
