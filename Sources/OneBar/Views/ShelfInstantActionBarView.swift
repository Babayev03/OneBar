import SwiftUI

/// The buttons themselves. Laid out with `ShelfInstantActionLayout` rather than
/// a stack, so the tile drawn here and the rectangle `ShelfInstantActionDropView`
/// accepts a file into are the same rectangle by construction rather than by
/// two sets of numbers agreeing.
struct ShelfInstantActionBarView: View {
    let model: ShelfInstantActionBarModel

    private var size: CGSize {
        ShelfInstantActionLayout.size(count: model.actions.count)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                let frame = ShelfInstantActionLayout.cellFrame(at: index)
                cell(
                    action,
                    available: model.isAvailable(index),
                    highlighted: model.highlighted == index
                )
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            }
        }
        .frame(width: size.width, height: size.height)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func cell(
        _ action: ShelfInstantAction,
        available: Bool,
        highlighted: Bool
    ) -> some View {
        VStack(spacing: 5) {
            Image(systemName: action.symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(highlighted ? Color.white : model.color)
                .frame(width: 40, height: 40)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(highlighted ? AnyShapeStyle(model.color) : AnyShapeStyle(.quaternary))
                }
            Text(action.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(highlighted ? model.color : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        // Dimmed rather than hidden: a strip whose buttons came and went as the
        // drag moved would be a different strip every time you looked at it.
        .opacity(available ? 1 : 0.35)
        .animation(.easeOut(duration: 0.12), value: highlighted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.activityLabel)
        .accessibilityHint(available ? "Drop to run" : "Does not apply to this drag")
    }
}
