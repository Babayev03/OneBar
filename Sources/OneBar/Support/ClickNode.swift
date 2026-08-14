import CoreGraphics
import Foundation
import Observation

enum ClickButton: String, Codable, CaseIterable, Identifiable {
    case left, right, middle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        case .middle: return "Middle"
        }
    }
}

/// One stop in a click sequence.
struct ClickNode: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Screen position in CoreGraphics space — top-left origin, spanning all
    /// displays. Stored the way `CGEvent` wants it so nothing has to be flipped
    /// at run time.
    var point: CGPoint
    var button: ClickButton = .left
    /// 1 = single click, 2 = double click. Posted as a real click count rather
    /// than two clicks in a row, which most apps would read as two singles.
    var clickCount: Int = 1
    /// Seconds to wait after this node before moving to the next.
    var delay: Double = 0.5
    /// Drawn size, purely visual — the click always lands on `point`.
    var radius: Double = 22
    var opacity: Double = 1
}

/// The working sequence, persisted so a setup survives a restart. Kept as a
/// plain list: order in the array is firing order.
@MainActor
@Observable
final class ClickSequence {
    static let shared = ClickSequence()

    private static let defaultsKey = "autoClickNodes"

    var nodes: [ClickNode] { didSet { save() } }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([ClickNode].self, from: data) {
            nodes = decoded
        } else {
            nodes = []
        }
    }

    func add(at point: CGPoint) {
        // Inherit the last node's settings: a sequence is usually a run of
        // similar clicks, and re-picking the button every time is tedious.
        var node = ClickNode(point: point)
        if let previous = nodes.last {
            node.button = previous.button
            node.clickCount = previous.clickCount
            node.delay = previous.delay
            node.radius = previous.radius
            node.opacity = previous.opacity
        }
        nodes.append(node)
    }

    func remove(_ id: UUID) {
        nodes.removeAll { $0.id == id }
    }

    func move(_ id: UUID, to point: CGPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].point = point
    }

    func update(_ node: ClickNode) {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        nodes[index] = node
    }

    func removeAll() {
        nodes = []
    }

    private func save() {
        if let data = try? JSONEncoder().encode(nodes) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
