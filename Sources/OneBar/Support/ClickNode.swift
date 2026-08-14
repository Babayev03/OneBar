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

enum ScrollDirection: String, Codable, CaseIterable, Identifiable {
    case up, down, left, right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    /// Raw wheel axis deltas: wheel1 is vertical, wheel2 horizontal, and both
    /// are positive going up and left.
    func delta(_ amount: Double) -> (vertical: Double, horizontal: Double) {
        switch self {
        case .up: return (amount, 0)
        case .down: return (-amount, 0)
        case .left: return (0, amount)
        case .right: return (0, -amount)
        }
    }
}

enum NodeKind: String, Codable, CaseIterable, Identifiable {
    case click, text, slide, scroll

    var id: String { rawValue }

    var title: String {
        switch self {
        case .click: return "Click"
        case .text: return "Text"
        case .slide: return "Slide"
        case .scroll: return "Scroll"
        }
    }

    var symbol: String {
        switch self {
        case .click: return "cursorarrow.click"
        case .text: return "character.cursor.ibeam"
        case .slide: return "arrow.left.and.right"
        case .scroll: return "arrow.up.arrow.down"
        }
    }
}

/// One stop in a click sequence.
struct ClickNode: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Screen position in CoreGraphics space — top-left origin, spanning all
    /// displays. Stored the way `CGEvent` wants it so nothing has to be flipped
    /// at run time. For a slide this is where the drag starts.
    var point: CGPoint
    var kind: NodeKind = .click
    var button: ClickButton = .left
    /// 1 = single click, 2 = double click. Posted as a real click count rather
    /// than two clicks in a row, which most apps would read as two singles.
    var clickCount: Int = 1
    /// Typed verbatim when `kind` is `.text`.
    var text: String = ""
    /// Where a slide releases. Nil until the node is switched to `.slide`.
    var slideTo: CGPoint?
    /// How long the drag itself takes, in seconds.
    var slideDuration: Double = 0.6
    var scrollDirection: ScrollDirection = .down
    /// How far to scroll, in pixels.
    var scrollDistance: Double = 400
    /// How long the scroll is spread over, in seconds.
    var scrollDuration: Double = 0.4
    /// Seconds to wait after this node before moving to the next.
    var delay: Double = 0.5
    /// Drawn size, purely visual — the action always lands on `point`.
    var radius: Double = 22
    var opacity: Double = 1

    init(point: CGPoint) {
        self.point = point
    }

    /// Hand-rolled so every field is optional on the way in: points saved by an
    /// earlier version predate `kind`, `text` and the slide fields, and the
    /// synthesized decoder would reject them outright rather than fall back to
    /// the defaults above.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        point = try container.decode(CGPoint.self, forKey: .point)
        kind = try container.decodeIfPresent(NodeKind.self, forKey: .kind) ?? .click
        button = try container.decodeIfPresent(ClickButton.self, forKey: .button) ?? .left
        clickCount = try container.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        slideTo = try container.decodeIfPresent(CGPoint.self, forKey: .slideTo)
        slideDuration = try container.decodeIfPresent(Double.self, forKey: .slideDuration) ?? 0.6
        scrollDirection = try container.decodeIfPresent(ScrollDirection.self, forKey: .scrollDirection) ?? .down
        scrollDistance = try container.decodeIfPresent(Double.self, forKey: .scrollDistance) ?? 400
        scrollDuration = try container.decodeIfPresent(Double.self, forKey: .scrollDuration) ?? 0.4
        delay = try container.decodeIfPresent(Double.self, forKey: .delay) ?? 0.5
        radius = try container.decodeIfPresent(Double.self, forKey: .radius) ?? 22
        opacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }

    /// Where a slide ends, defaulted to the right of the start so a node
    /// switched to slide mode has a handle to grab straight away.
    var slideEnd: CGPoint {
        slideTo ?? CGPoint(x: point.x + 140, y: point.y)
    }

    var summary: String {
        switch kind {
        case .click:
            return "\(clickCount == 2 ? "Double" : "Single") \(button.title.lowercased()) click"
        case .text:
            return text.isEmpty ? "No text yet" : "Types “\(text.prefix(24))\(text.count > 24 ? "…" : "")”"
        case .slide:
            return String(format: "Drags over %.1fs", slideDuration)
        case .scroll:
            return "Scrolls \(scrollDirection.title.lowercased()) \(Int(scrollDistance))px"
        }
    }
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
        // Carry the slide's endpoint along, so dragging a slide node relocates
        // the whole gesture instead of stretching it.
        if nodes[index].kind == .slide, let end = nodes[index].slideTo {
            let end = CGPoint(
                x: end.x + (point.x - nodes[index].point.x),
                y: end.y + (point.y - nodes[index].point.y)
            )
            nodes[index].slideTo = end
        }
        nodes[index].point = point
    }

    func moveSlideEnd(_ id: UUID, to point: CGPoint) {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else { return }
        nodes[index].slideTo = point
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
