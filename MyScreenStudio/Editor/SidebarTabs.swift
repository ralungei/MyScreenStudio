import SwiftUI

// MARK: - Reusable Inspector Components

/// Lightweight section grouping — NO material background (avoids glass-on-glass).
/// Uses header label + spacing for visual separation.
struct InspectorSection<Content: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            content()
        }
    }
}

/// Compact slider for inspector sidebars — title + value on top, continuous Slider below.
/// No step marks — clean, minimal appearance.
private struct CompactSlider: View {
    let label: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat
    let unit: String

    init(_ label: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat = 1, unit: String = "px") {
        self.label = label
        self._value = value
        self.range = range
        self.step = step
        self.unit = unit
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text(formattedValue)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
        }
    }

    private var formattedValue: String {
        switch unit {
        case "%": "\(Int(value * 100))%"
        case "x": String(format: "%.1fx", value)
        default: "\(Int(value))\(unit)"
        }
    }
}

/// Glass pill button — uses Button for proper hit testing + interactive glass.
private struct PillButton: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isActive
                ? .regular.tint(.accentColor).interactive()
                : .regular.interactive(),
            in: .capsule
        )
    }
}

// MARK: - Background Config Tab

struct BackgroundConfigTab: View {
    @Bindable var backgroundManager: BackgroundManager
    @State private var selectedCategory: VideoBackground.BackgroundCategory = .gradients

    private let categories = VideoBackground.BackgroundCategory.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Background")
                .font(.headline)

            // Wallpaper
            InspectorSection(icon: "photo", title: "Wallpaper") {
                GlassEffectContainer {
                    FlowLayout(spacing: 4) {
                        ForEach(categories, id: \.self) { category in
                            PillButton(
                                label: category.displayName,
                                isActive: selectedCategory == category,
                                action: { selectedCategory = category }
                            )
                        }
                    }
                }

                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 48, maximum: 60))
                ], spacing: 6) {
                    ForEach(filteredBackgrounds) { background in
                        BackgroundPreviewView(
                            background: background,
                            isSelected: backgroundManager.settings.selectedBackground?.id == background.id,
                            onSelect: { backgroundManager.selectBackground(background) }
                        )
                    }
                }
            }

            // Frame
            InspectorSection(icon: "rectangle.dashed", title: "Window Frame") {
                CompactSlider("Padding", value: $backgroundManager.settings.padding, range: 0...200, step: 10)
                CompactSlider("Corner Radius", value: $backgroundManager.settings.cornerRadius, range: 0...50, step: 5)
            }

            // Shadow
            InspectorSection(icon: "shadow", title: "Shadow") {
                Toggle("Drop Shadow", isOn: $backgroundManager.settings.shadowEnabled)
                    .font(.caption)

                if backgroundManager.settings.shadowEnabled {
                    CompactSlider("Opacity", value: $backgroundManager.settings.shadowOpacity, range: 0...1, step: 0.05, unit: "%")
                    CompactSlider("Blur", value: $backgroundManager.settings.shadowBlur, range: 0...60, step: 5)
                    CompactSlider("Offset Y", value: $backgroundManager.settings.shadowOffset.height, range: 0...30, step: 2)
                }
            }
        }
    }

    private var filteredBackgrounds: [VideoBackground] {
        if selectedCategory == .none {
            return backgroundManager.availableBackgrounds.filter { $0.category == .none }
        }
        return backgroundManager.availableBackgrounds.filter { $0.category == selectedCategory }
    }
}

// MARK: - Flow Layout

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.reduce(CGFloat(0)) { acc, row in
            acc + row.height + (acc > 0 ? spacing : 0)
        }
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        var idx = 0
        for row in rows {
            var x = bounds.minX
            for _ in 0..<row.count {
                let size = subviews[idx].sizeThatFits(.unspecified)
                subviews[idx].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
                idx += 1
            }
            y += row.height + spacing
        }
    }

    private struct Row { var count: Int; var height: CGFloat }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [Row] {
        let maxW = proposal.width ?? .infinity
        var rows: [Row] = []
        var currentW: CGFloat = 0
        var currentH: CGFloat = 0
        var currentCount = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            let needed = currentCount > 0 ? size.width + spacing : size.width
            if currentW + needed > maxW && currentCount > 0 {
                rows.append(Row(count: currentCount, height: currentH))
                currentW = size.width
                currentH = size.height
                currentCount = 1
            } else {
                currentW += needed
                currentH = max(currentH, size.height)
                currentCount += 1
            }
        }
        if currentCount > 0 {
            rows.append(Row(count: currentCount, height: currentH))
        }
        return rows
    }
}

// MARK: - Cursor Config Tab

struct CursorConfigTab: View {
    @Bindable var cursorManager: CursorManager

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Cursor")
                .font(.headline)

            // Style + grid
            InspectorSection(icon: "cursorarrow", title: "Style") {
                Toggle("Show Cursor", isOn: $cursorManager.isEnabled)
                    .font(.caption)

                if cursorManager.isEnabled {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 45, maximum: 55))
                    ], spacing: 12) {
                        ForEach(cursorManager.availableCursors) { cursor in
                            CursorPreviewView(
                                cursor: cursor,
                                isSelected: cursorManager.selectedCursor?.id == cursor.id,
                                onSelect: { cursorManager.selectCursor(cursor) }
                            )
                        }
                    }
                }
            }

            if cursorManager.isEnabled {
                // Appearance + Motion (merged)
                InspectorSection(icon: "paintbrush", title: "Appearance") {
                    CompactSlider("Size", value: $cursorManager.cursorScale, range: 0.5...3.0, step: 0.1, unit: "x")
                    CompactSlider("Opacity", value: $cursorManager.cursorOpacity, range: 0.3...1.0, step: 0.05, unit: "%")
                    Toggle("Drop Shadow", isOn: $cursorManager.cursorShadow)
                        .font(.caption)
                    Divider()
                    CompactSlider("Smoothing", value: $cursorManager.smoothing, range: 0.02...0.5, step: 0.02)
                    Text(smoothingLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Click Effects
                InspectorSection(icon: "hand.tap", title: "Click Effects") {
                    Toggle("Show Click Effects", isOn: $cursorManager.showClickEffects)
                        .font(.caption)

                    if cursorManager.showClickEffects {
                        Picker("Style", selection: $cursorManager.clickEffectStyle) {
                            ForEach(ClickEffectStyle.allCases, id: \.self) { style in
                                Text(style.rawValue).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        HStack {
                            Text("Color").font(.caption)
                            Spacer()
                            ColorPicker("", selection: $cursorManager.clickEffectColor, supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 24, height: 24)
                        }

                        CompactSlider("Size", value: $cursorManager.clickEffectSize, range: 0.5...2.0, step: 0.1, unit: "x")
                    }
                }
            }
        }
    }

    private var smoothingLabel: String {
        if cursorManager.smoothing < 0.08 { return "Very smooth" }
        if cursorManager.smoothing < 0.2 { return "Balanced" }
        return "Snappy"
    }
}

// MARK: - Audio Config Tab

struct AudioConfigTab: View {
    @Binding var recordAudio: Bool
    @Binding var audioSource: String
    @Binding var systemVolume: CGFloat
    @Binding var micVolume: CGFloat
    @Bindable var clickSoundPlayer: ClickSoundPlayer
    @Bindable var zoomSoundPlayer: ZoomSoundPlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio")
                .font(.headline)

            InspectorSection(icon: "mic.fill", title: "Recording") {
                Toggle("Record Audio", isOn: $recordAudio)
                    .font(.caption)
            }

            if recordAudio {
                InspectorSection(icon: "speaker.wave.2", title: "Source") {
                    Picker("Source", selection: $audioSource) {
                        Text("System").tag("system")
                        Text("Mic").tag("microphone")
                        Text("Both").tag("both")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                InspectorSection(icon: "slider.horizontal.3", title: "Levels") {
                    if audioSource == "system" || audioSource == "both" {
                        CompactSlider("System", value: $systemVolume, range: 0...1, step: 0.05, unit: "%")
                    }
                    if audioSource == "microphone" || audioSource == "both" {
                        CompactSlider("Microphone", value: $micVolume, range: 0...1, step: 0.05, unit: "%")
                    }
                }
            }

            Divider()

            InspectorSection(icon: "computermouse.fill", title: "Click Sounds") {
                Toggle("Enable Click Sounds", isOn: $clickSoundPlayer.isEnabled)
                    .font(.caption)

                if clickSoundPlayer.isEnabled {
                    // Sound style picker — plays preview on hover
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sound")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            ForEach(ClickSoundStyle.allCases, id: \.self) { style in
                                ClickSoundPill(
                                    style: style,
                                    isSelected: clickSoundPlayer.style == style,
                                    onSelect: { clickSoundPlayer.style = style },
                                    onPreview: { clickSoundPlayer.playStyle(style) }
                                )
                            }
                        }
                    }

                    CompactSlider("Volume", value: $clickSoundPlayer.volume, range: 0...1, step: 0.05, unit: "%")
                }
            }

            Divider()

            InspectorSection(icon: "speaker.wave.2", title: "Zoom Sounds") {
                Toggle("Enable Zoom Sounds", isOn: $zoomSoundPlayer.isEnabled)
                    .font(.caption)

                if zoomSoundPlayer.isEnabled {
                    CompactSlider("Volume", value: $zoomSoundPlayer.volume, range: 0...1, step: 0.05, unit: "%")
                }
            }
        }
    }
}

/// Pill button for click sound selection — plays preview on hover.
private struct ClickSoundPill: View {
    let style: ClickSoundStyle
    let isSelected: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void

    var body: some View {
        Button {
            onSelect()
            onPreview()
        } label: {
            Text(style.rawValue)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected
                ? .regular.tint(.accentColor).interactive()
                : .regular.interactive(),
            in: .capsule
        )
        .onHover { hovering in
            if hovering { onPreview() }
        }
    }
}
