import AppKit
import SwiftUI

/// The transparent editing surface for one display. Click empty space to drop a
/// point, drag a point to move it, select one to tune what it does.
struct ClickCanvasView: View {
    let screen: NSScreen
    let isPrimary: Bool

    private var sequence: ClickSequence { ClickSequence.shared }
    private var canvas: ClickCanvasModel { ClickCanvasModel.shared }
    private var clicker: AutoClickService { AutoClickService.shared }
    private var accent: Color { AppState.shared.accentColor }

    private struct Drag: Equatable {
        var id: UUID
        var isEnd: Bool
        var translation: CGSize
    }

    private var layouts: ClickLayoutStore { ClickLayoutStore.shared }

    @State private var drag: Drag?
    @State private var isNamingLayout = false
    @State private var layoutName = ""

    private var turbo: TurboClickService { TurboClickService.shared }

    var body: some View {
        ZStack(alignment: .topLeading) {
            placementSurface
            chain
            nodes
            if isPrimary {
                toolbar
                inspector
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Placing

    private var placementSurface: some View {
        Color.white.opacity(0.001)
            .contentShape(Rectangle())
            // A zero-distance drag rather than a tap: it reports where the press
            // landed, which is the whole point here.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { value in
                        guard !clicker.isRunning else { return }
                        guard hypot(value.translation.width, value.translation.height) < 4 else { return }
                        if canvas.selection != nil {
                            canvas.selection = nil
                        } else {
                            sequence.add(at: eventPoint(from: value.location))
                        }
                    }
            )
    }

    // MARK: - Ghost chain

    private var chain: some View {
        Path { path in
            let points = sequence.nodes.map { local(for: $0.point) }
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
        }
        .stroke(
            accent.opacity(0.45),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 5])
        )
        .allowsHitTesting(false)
    }

    // MARK: - Nodes

    private var nodes: some View {
        ForEach(Array(sequence.nodes.enumerated()), id: \.element.id) { index, node in
            Group {
                if node.kind == .slide {
                    slideTrack(node)
                    slideEndHandle(node)
                }
                nodeView(node, index: index + 1)
            }
        }
    }

    /// The line a slide travels along, drawn solid so it reads differently from
    /// the dashed chain that orders the sequence.
    private func slideTrack(_ node: ClickNode) -> some View {
        Path { path in
            path.move(to: displayPosition(for: node))
            path.addLine(to: displayEndPosition(for: node))
        }
        .stroke(accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        .opacity(node.opacity)
        .allowsHitTesting(false)
    }

    private func slideEndHandle(_ node: ClickNode) -> some View {
        let size = max(14, node.radius * 1.2)
        return ZStack {
            Circle().fill(accent.opacity(0.18))
            Circle().strokeBorder(accent, style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
            Image(systemName: "arrow.down.right")
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .opacity(node.opacity)
        .position(displayEndPosition(for: node))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !clicker.isRunning else { return }
                    canvas.selection = node.id
                    drag = Drag(id: node.id, isEnd: true, translation: value.translation)
                }
                .onEnded { value in
                    guard !clicker.isRunning else { return }
                    drag = nil
                    var position = local(for: node.slideEnd)
                    position.x += value.translation.width
                    position.y += value.translation.height
                    sequence.moveSlideEnd(node.id, to: eventPoint(from: position))
                }
        )
    }

    private func nodeView(_ node: ClickNode, index: Int) -> some View {
        let isSelected = canvas.selection == node.id
        let isFiring = clicker.currentNode == node.id
        let size = node.radius * 2

        return ZStack {
            Circle()
                .fill(accent.opacity(isFiring ? 0.55 : 0.22))
            Circle()
                .strokeBorder(
                    isSelected ? Color.white : accent,
                    lineWidth: isSelected ? 2.5 : 1.5
                )
            Text("\(index)")
                .font(.system(size: max(10, node.radius * 0.7), weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            if node.kind != .click {
                Image(systemName: node.kind.symbol)
                    .font(.system(size: max(7, node.radius * 0.42), weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(accent, in: Circle())
                    .offset(x: node.radius * 0.75, y: node.radius * 0.75)
            }
        }
        .frame(width: size, height: size)
        .opacity(node.opacity)
        .scaleEffect(isFiring ? 1.25 : 1)
        .animation(.spring(duration: 0.2), value: isFiring)
        .position(displayPosition(for: node))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard !clicker.isRunning else { return }
                    canvas.selection = node.id
                    drag = Drag(id: node.id, isEnd: false, translation: value.translation)
                }
                .onEnded { value in
                    guard !clicker.isRunning else { return }
                    drag = nil
                    // Only commit real moves, so a plain click just selects
                    // rather than nudging the point off target.
                    guard hypot(value.translation.width, value.translation.height) >= 4 else { return }
                    var position = local(for: node.point)
                    position.x += value.translation.width
                    position.y += value.translation.height
                    sequence.move(node.id, to: eventPoint(from: position))
                }
        )
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button {
                if clicker.isRunning {
                    clicker.stop()
                } else {
                    AppState.shared.autoClickActive = clicker.start()
                }
            } label: {
                Label(
                    clicker.isRunning ? "Stop" : "Run",
                    systemImage: clicker.isRunning ? "stop.fill" : "play.fill"
                )
            }
            .keyboardShortcut(.return, modifiers: .command)

            Divider().frame(height: 16)

            Text("\(sequence.nodes.count) point\(sequence.nodes.count == 1 ? "" : "s")")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Clear All") { sequence.removeAll() }
                .disabled(sequence.nodes.isEmpty || clicker.isRunning)

            layoutMenu

            Divider().frame(height: 16)

            Text(clicker.isRunning ? "Press Esc to stop" : "Click anywhere to add a point")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Done") { ClickCanvasController.shared.close() }
                .disabled(clicker.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlass(in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 44)
        .alert("Save layout", isPresented: $isNamingLayout) {
            TextField("Name", text: $layoutName)
            Button("Save") {
                layouts.save(layoutName, nodes: sequence.nodes)
                layoutName = ""
            }
            Button("Cancel", role: .cancel) { layoutName = "" }
        } message: {
            Text("Saving over an existing name replaces it.")
        }
    }

    private var layoutMenu: some View {
        Menu {
            Button("Save Current…") { isNamingLayout = true }
                .disabled(sequence.nodes.isEmpty)

            if !layouts.layouts.isEmpty {
                Divider()
                ForEach(layouts.layouts) { layout in
                    Button("\(layout.name)  (\(layout.nodes.count))") {
                        sequence.nodes = layout.nodes
                        canvas.selection = nil
                    }
                }
                Divider()
                Menu("Delete") {
                    ForEach(layouts.layouts) { layout in
                        Button(layout.name) { layouts.delete(layout.id) }
                    }
                }
            }
        } label: {
            Label("Layouts", systemImage: "square.stack")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(clicker.isRunning)
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let id = canvas.selection,
           let index = sequence.nodes.firstIndex(where: { $0.id == id }) {
            let node = sequence.nodes[index]

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Point \(index + 1)")
                            .font(.headline)
                        Text(node.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        canvas.selection = nil
                        sequence.remove(id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }

                Picker("Mode", selection: kindBinding(id)) {
                    ForEach(NodeKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)

                switch node.kind {
                case .click:
                    Picker("Button", selection: binding(id, \.button, default: .left)) {
                        ForEach(ClickButton.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    Picker("Clicks", selection: binding(id, \.clickCount, default: 1)) {
                        Text("Single").tag(1)
                        Text("Double").tag(2)
                    }
                    .pickerStyle(.segmented)

                case .text:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Types at this point")
                            .font(.callout)
                        TextField("Text to type", text: binding(id, \.text, default: ""), axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...5)
                    }

                case .slide:
                    Picker("Button", selection: binding(id, \.button, default: .left)) {
                        ForEach(ClickButton.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    labelled("Drag time", value: String(format: "%.2fs", node.slideDuration)) {
                        Slider(value: binding(id, \.slideDuration, default: 0.6), in: 0.1...5)
                    }

                    Text("Drag the dashed handle to set where the slide releases.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                case .scroll:
                    Picker("Direction", selection: binding(id, \.scrollDirection, default: .down)) {
                        ForEach(ScrollDirection.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    labelled("Distance", value: "\(Int(node.scrollDistance)) px") {
                        Slider(value: binding(id, \.scrollDistance, default: 400), in: 50...3000)
                    }

                    labelled("Over", value: String(format: "%.2fs", node.scrollDuration)) {
                        Slider(value: binding(id, \.scrollDuration, default: 0.4), in: 0.05...3)
                    }

                    Text("Scrolls whatever sits under this point. Nothing is pressed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                labelled("Wait after", value: String(format: "%.2fs", node.delay)) {
                    Slider(value: binding(id, \.delay, default: 0.5), in: 0.05...10)
                }
                labelled("Size", value: "\(Int(node.radius))") {
                    Slider(value: binding(id, \.radius, default: 22), in: 8...60)
                }
                labelled("Opacity", value: "\(Int(node.opacity * 100))%") {
                    Slider(value: binding(id, \.opacity, default: 1), in: 0.1...1)
                }
            }
            .frame(width: 260)
            .padding(16)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(28)
        }
    }

    private func labelled<Content: View>(
        _ title: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func kindBinding(_ id: UUID) -> Binding<NodeKind> {
        Binding(
            get: { ClickSequence.shared.nodes.first { $0.id == id }?.kind ?? .click },
            set: { newValue in
                guard let index = ClickSequence.shared.nodes.firstIndex(where: { $0.id == id }) else { return }
                // Pin the endpoint on the way into slide mode: until it's a real
                // value the handle has nothing to write back to.
                if newValue == .slide, ClickSequence.shared.nodes[index].slideTo == nil {
                    ClickSequence.shared.nodes[index].slideTo = ClickSequence.shared.nodes[index].slideEnd
                }
                ClickSequence.shared.nodes[index].kind = newValue
            }
        )
    }

    /// Resolved by id, not index: a binding outlives the render that made it,
    /// and deleting a node would leave a stale index pointing off the end.
    private func binding<Value>(
        _ id: UUID,
        _ keyPath: WritableKeyPath<ClickNode, Value>,
        default fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: {
                ClickSequence.shared.nodes.first { $0.id == id }?[keyPath: keyPath] ?? fallback
            },
            set: { newValue in
                guard let index = ClickSequence.shared.nodes.firstIndex(where: { $0.id == id }) else { return }
                ClickSequence.shared.nodes[index][keyPath: keyPath] = newValue
            }
        )
    }

    // MARK: - Coordinates

    /// Nodes live in event space (top-left origin across all displays); a view
    /// only knows about its own window, so everything is offset by the screen.
    private func local(for point: CGPoint) -> CGPoint {
        let origin = screen.eventSpaceOrigin
        return CGPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    private func eventPoint(from point: CGPoint) -> CGPoint {
        let origin = screen.eventSpaceOrigin
        return CGPoint(x: point.x + origin.x, y: point.y + origin.y)
    }

    private func displayPosition(for node: ClickNode) -> CGPoint {
        var position = local(for: node.point)
        if let drag, drag.id == node.id, !drag.isEnd {
            position.x += drag.translation.width
            position.y += drag.translation.height
        }
        return position
    }

    private func displayEndPosition(for node: ClickNode) -> CGPoint {
        var position = local(for: node.slideEnd)
        if let drag, drag.id == node.id {
            // Dragging the start carries the whole gesture; dragging the end
            // just stretches it.
            position.x += drag.translation.width
            position.y += drag.translation.height
        }
        return position
    }
}
