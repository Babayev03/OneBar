import SwiftUI

struct ClipboardPanelView: View {
    @Bindable var model: ClipboardPanelModel
    @FocusState private var searchFocused: Bool
    @Namespace private var selectionNS
    @Namespace private var chipNS

    private var accent: Color { AppState.shared.accentColor }

    var body: some View {
        ZStack {
            VStack(spacing: 12) {
                searchBar
                filterChips

                if model.filteredItems.isEmpty {
                    emptyState
                } else if model.isPresented {
                    // List inserts on present so cells enter via transitions,
                    // which always settle fully visible.
                    itemList
                } else {
                    Spacer()
                }
            }
            .padding(14)

            if model.showPreview, let item = model.selectedItem {
                PreviewOverlay(item: item) {
                    model.showPreview = false
                }
                .transition(.blurReplace.combined(with: .scale(0.96)))
            }
        }
        .animation(.smooth(duration: 0.25), value: model.showPreview)
        .frame(width: 520, height: 640)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .scaleEffect(model.isPresented ? 1 : 0.96, anchor: .top)
        .onChange(of: model.searchFieldFocused) { _, focused in
            searchFocused = focused
        }
        .onChange(of: searchFocused) { _, focused in
            model.searchFieldFocused = focused
        }
        .onChange(of: model.searchText) { _, _ in
            model.selectFirst()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            // Own placeholder drawn on top: the built-in one shifts when the
            // field editor takes over on focus.
            ZStack(alignment: .leading) {
                if model.searchText.isEmpty {
                    Text("Press S to search")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                TextField("", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .frame(height: 20)
                    .focused($searchFocused)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .liquidGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var filterChips: some View {
        HStack(spacing: 6) {
            ForEach(PanelFilter.allCases, id: \.self) { filter in
                let isActive = model.filter == filter
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        model.filter = filter
                        model.closeActions()
                        model.selectFirst()
                    }
                } label: {
                    Text(filter.rawValue)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isActive ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .background {
                    if isActive {
                        Capsule()
                            .fill(accent.opacity(0.25))
                            .matchedGeometryEffect(id: "chip", in: chipNS)
                    }
                }
                .overlay {
                    if isActive {
                        Capsule()
                            .strokeBorder(accent.opacity(0.8), lineWidth: 1.5)
                            .matchedGeometryEffect(id: "chip-stroke", in: chipNS)
                    }
                }
            }
            Spacer()
            Text("Tab")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .help("Tab cycles filters")
        }
        .padding(.horizontal, 2)
    }

    private var itemList: some View {
        let pinned = model.filteredItems.filter(\.isPinned)
        let recent = model.filteredItems.filter { !$0.isPinned }

        return ScrollViewReader { proxy in
            ScrollView {
                // Non-lazy on purpose: LazyVStack destroys cells that get
                // pushed off-screen, and their removal snapshots ghost over
                // the actions popup.
                VStack(spacing: 10) {
                    if !pinned.isEmpty {
                        sectionHeader("Pinned", systemImage: "pin.fill")
                        cells(pinned, indexOffset: 0)
                    }
                    if !recent.isEmpty {
                        if !pinned.isEmpty {
                            sectionHeader("Recent", systemImage: "clock")
                        }
                        cells(recent, indexOffset: pinned.count)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
            .scrollIndicators(.never)
            .animation(.smooth(duration: 0.28), value: model.selectedID)
            .animation(.smooth(duration: 0.25), value: model.showActions)
            .onChange(of: model.selectedID) { _, id in
                if let id {
                    withAnimation(.smooth(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: nil)
                    }
                }
            }
            .onChange(of: model.showActions) { _, shown in
                guard shown, let id = model.selectedID else { return }
                // Let the popup take its layout size, then bring the whole
                // cell (card + actions) fully into view.
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    withAnimation(.smooth(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: model.actionIndex) { _, _ in
                guard model.showActions, let id = model.selectedID else { return }
                withAnimation(.smooth(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.8)
            Spacer()
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    private func cells(_ items: [ClipboardItem], indexOffset: Int) -> some View {
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            let isSelected = item.id == model.selectedID
            let globalIndex = index + indexOffset
            VStack(spacing: 8) {
                ClipboardCardView(item: item)
                    .background(
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                            if isSelected {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(LinearGradient(
                                        colors: [accent.opacity(0.35), accent.opacity(0.15)],
                                        startPoint: .topLeading, endPoint: .bottomTrailing))
                                    .matchedGeometryEffect(id: "selection-bg", in: selectionNS)
                            }
                        }
                    )
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(accent.opacity(0.9), lineWidth: 2)
                                .matchedGeometryEffect(id: "selection-stroke", in: selectionNS)
                        } else {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(TapGesture(count: 2).onEnded {
                        PasteService.paste(item, plainText: false)
                    })
                    .simultaneousGesture(TapGesture().onEnded {
                        if model.selectedID == item.id {
                            if model.showActions {
                                model.closeActions()
                            } else {
                                model.openActions()
                            }
                        } else {
                            model.selectedID = item.id
                            model.closeActions()
                        }
                    })

                if model.showActions && isSelected {
                    ActionsPopup(item: item, model: model)
                        .transition(
                            .scale(scale: 0.92, anchor: .top).combined(with: .opacity)
                        )
                }
            }
            .id(item.id)
            // Popup must cover the card below it while everything animates.
            .zIndex(isSelected ? 1 : 0)
            // Staggered cascade whenever a cell is inserted (panel open,
            // filter change, new copies).
            // The removed row must stop being drawn in the same frame it is
            // deleted. A removed row leaves the layout immediately — that is
            // what lets the row below slide up into the freed slot — but it
            // keeps being painted until its removal transition finishes, so
            // any non-zero removal duration (including `.identity`, which
            // paints the row unchanged for the whole transaction) makes the
            // row below travel straight through it. A zero-length removal
            // drops it instantly while the reflow below still animates.
            .transition(.asymmetric(
                insertion: .opacity.combined(with: .offset(y: 14))
                    .animation(.smooth(duration: 0.3).delay(min(Double(globalIndex) * 0.025, 0.25))),
                removal: .opacity.animation(.linear(duration: 0))
            ))
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "clipboard")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.searchText.isEmpty ? "Nothing here yet" : "No matches")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Full preview (Spacebar)

struct PreviewOverlay: View {
    let item: ClipboardItem
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                if let icon = item.sourceAppIcon {
                    Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                }
                Text(item.sourceAppName ?? "Unknown source")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Text(item.timeString)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            switch item.kind {
            case .image:
                if let url = ClipboardStore.shared.imageURL(for: item),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let ocr = item.ocrText {
                    ScrollView {
                        Text(ocr)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                }
            case .text:
                ScrollView {
                    Text(item.text ?? "")
                        .font(.system(size: 13))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }

            Text("Space or Esc to close")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(24)
    }
}

// MARK: - Actions popup

struct ActionsPopup: View {
    let item: ClipboardItem
    let model: ClipboardPanelModel

    @Namespace private var actionNS

    private var accent: Color { AppState.shared.accentColor }

    var body: some View {
        VStack(spacing: 6) {
            // Highlight follows the arrow keys only; hovering doesn't move it.
            ForEach(Array(PanelAction.actions(for: item).enumerated()), id: \.offset) { index, action in
                actionRow(action, isHighlighted: index == model.actionIndex)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        // Single highlight that slides between rows, same as card selection.
        .animation(.smooth(duration: 0.28), value: model.actionIndex)
    }

    private func actionRow(_ action: PanelAction, isHighlighted: Bool) -> some View {
        Button {
            ClipboardPanelController.shared.perform(action, on: item)
        } label: {
            HStack {
                Text(action.title)
                    .font(.system(size: 14, weight: .medium))
                Spacer()
                if let key = action.keyLabel {
                    Text(key)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if isHighlighted {
                Capsule()
                    .fill(accent.opacity(0.18))
                    .matchedGeometryEffect(id: "action-bg", in: actionNS)
            }
        }
        // Thick material so the card being pushed down never shows through.
        .background(Capsule().fill(.thickMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .overlay {
            if isHighlighted {
                Capsule()
                    .strokeBorder(accent.opacity(0.9), lineWidth: 2)
                    .matchedGeometryEffect(id: "action-stroke", in: actionNS)
            }
        }
    }
}
