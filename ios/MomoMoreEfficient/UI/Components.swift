import SwiftUI

// MARK: - Page chrome

/// The circular back control the atlas uses instead of a system back button.
struct BackCircleButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .frame(width: Theme.minimumTarget, height: Theme.minimumTarget)
                .background(Theme.surface, in: Circle())
                .overlay(Circle().strokeBorder(Theme.separator, lineWidth: Theme.hairline))
        }
        .accessibilityLabel("返回")
    }
}

struct PageTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.pageTitle)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// `连接状态 ✓ 已连接` / `连接状态 未连接 · 去设置`.
///
/// A status line on a work surface, not a control group: the only interactive
/// part is `去设置`. Connection is carried by dot *shape* plus text, never by
/// color alone.
struct ConnectionStatusLine: View {
    let isConnected: Bool
    var onOpenSettings: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.gapS) {
            Text("连接状态")
                .font(Theme.label)
                .foregroundStyle(Theme.textSecondary)
            if isConnected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink)
                Text("已连接")
                    .font(Theme.label)
                    .foregroundStyle(Theme.ink)
            } else {
                Circle()
                    .strokeBorder(Theme.textSecondary, lineWidth: 1.5)
                    .frame(width: 14, height: 14)
                Text("未连接")
                    .font(Theme.label)
                    .foregroundStyle(Theme.textSecondary)
                if let onOpenSettings {
                    Button("去设置", action: onOpenSettings)
                        .font(Theme.caption.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: Theme.hairline))
                        .minimumHitArea()
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isConnected ? "连接状态 已连接" : "连接状态 未连接")
    }
}

// MARK: - Grouped rows

/// A grouped card with a small secondary title above and an optional footnote
/// below, matching the Settings/Preferences layout.
struct GroupedCard<Content: View>: View {
    var title: String?
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gapS) {
            if let title {
                Text(title)
                    .font(Theme.label)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.textInset)
            }
            VStack(spacing: 0) { content }
                .themedCard()
                .padding(.horizontal, Theme.pageMargin)
            if let footnote {
                Text(footnote)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.textInset)
            }
        }
    }
}

/// One grouped row. `ViewThatFits` lets the label and value stack vertically at
/// accessibility sizes instead of truncating.
struct GroupedRow<Trailing: View>: View {
    let label: String
    var isDestructive = false
    var showsChevron = false
    var action: (() -> Void)?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Group {
            if let action {
                Button(action: action) { rowBody }
                    .buttonStyle(.plain)
            } else {
                rowBody
            }
        }
        .frame(minHeight: Theme.rowMinHeight)
        .padding(.horizontal, Theme.rowPaddingH)
        .contentShape(Rectangle())
    }

    private var rowBody: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.gapM) {
                labelText
                Spacer(minLength: Theme.gapM)
                trailing
                chevron
            }
            VStack(alignment: .leading, spacing: 4) {
                labelText
                HStack(spacing: Theme.gapS) {
                    trailing
                    Spacer(minLength: 0)
                    chevron
                }
            }
            .padding(.vertical, Theme.gapS)
        }
    }

    private var labelText: some View {
        Text(label)
            .font(Theme.row)
            .foregroundStyle(isDestructive ? Theme.alert : Theme.ink)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var chevron: some View {
        if showsChevron {
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

extension GroupedRow where Trailing == EmptyView {
    init(
        label: String,
        isDestructive: Bool = false,
        showsChevron: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.init(
            label: label,
            isDestructive: isDestructive,
            showsChevron: showsChevron,
            action: action,
            trailing: { EmptyView() }
        )
    }
}

/// A trailing value in a grouped row.
struct RowValue: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.rowValue)
            .foregroundStyle(Theme.textSecondary)
            .monospacedDigit()
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.separator)
            .frame(height: Theme.hairline)
            .padding(.leading, Theme.rowPaddingH)
    }
}

// MARK: - Actions

/// The one primary action per screen: a 56pt ink pill.
///
/// A disabled primary button stays visible and looks intentionally disabled, and
/// the caller supplies a why-line whenever the reason is not obvious.
struct PrimaryPillButton: View {
    let title: String
    var isLoading = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.gapS) {
                if isLoading { ProgressView().tint(Theme.onInk) }
                Text(title)
                    .font(Theme.primaryButton)
                    .monospacedDigit()
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(isEnabled ? Theme.onInk : Theme.disabledText)
            .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
            .background(
                isEnabled ? Theme.ink : Theme.disabledFill,
                in: RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
            )
        }
        .disabled(!isEnabled || isLoading)
    }
}

struct SecondaryPillButton: View {
    let title: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.primaryButton)
                .monospacedDigit()
                .foregroundStyle(isEnabled ? Theme.ink : Theme.disabledText)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: Theme.controlHeight)
                .background(
                    Theme.surface,
                    in: RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: Theme.hairline)
                )
        }
        .disabled(!isEnabled)
    }
}

/// A compact 44pt pill used for navigation and sheet triggers (设置, 筛选, 返回结果).
struct NavPill: View {
    let title: String
    var isProminent = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.chip)
                .monospacedDigit()
                .foregroundStyle(foreground)
                .padding(.horizontal, Theme.rowPaddingH)
                .frame(minHeight: Theme.minimumTarget)
                .background(background, in: Capsule())
                .overlay(
                    isProminent
                        ? nil
                        : Capsule().strokeBorder(Theme.separator, lineWidth: Theme.hairline)
                )
        }
        .disabled(!isEnabled)
    }

    private var foreground: Color {
        guard isEnabled else { return Theme.disabledText }
        return isProminent ? Theme.onInk : Theme.ink
    }

    private var background: Color {
        guard isEnabled else { return Theme.disabledFill }
        return isProminent ? Theme.ink : Theme.surface
    }
}

/// A two-, three- or four-value segmented control.
///
/// The selected value is carried by position, fill *and* label, and exposes the
/// live `已选择` / `未选择` accessibility value the app already uses elsewhere.
struct SegmentControl<Value: Hashable>: View {
    let values: [Value]
    let label: (Value) -> String
    @Binding var selection: Value
    var isEnabled = true

    var body: some View {
        HStack(spacing: 4) {
            ForEach(values, id: \.self) { value in
                let isSelected = value == selection
                Button {
                    selection = value
                } label: {
                    Text(label(value))
                        .font(Theme.chip)
                        .foregroundStyle(segmentForeground(isSelected: isSelected))
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(
                            isSelected ? Theme.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityValue(isSelected ? "已选择" : "未选择")
            }
        }
        .padding(4)
        .frame(minHeight: Theme.minimumTarget)
        .background(
            Theme.surfaceMuted,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .opacity(isEnabled ? 1 : 0.6)
    }

    private func segmentForeground(isSelected: Bool) -> Color {
        guard isEnabled else { return Theme.disabledText }
        return isSelected ? Theme.onAccent : Theme.textSecondary
    }
}

// MARK: - Feedback

/// One ink line with a ✓ dot. Acknowledgement is never green.
struct AckLine: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.footnote)
            Text(text)
                .font(Theme.label)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Theme.ink)
        .accessibilityElement(children: .combine)
    }
}

/// One alert-colored line in a fixed slot. Diagnostics live in receipts only.
struct ErrorLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.label)
            .foregroundStyle(Theme.alert)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CaptionLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.caption)
            .foregroundStyle(Theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A banner for a batch-level state: a title, an optional body, an optional
/// action. Tone changes the accent, never the only channel of meaning.
struct Banner: View {
    enum Tone {
        /// Informational — a restored result, an account change.
        case neutral
        /// A stop the Owner should read.
        case stop
    }

    let title: String
    var message: String?
    var tone: Tone = .neutral
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.label.weight(.semibold))
                .foregroundStyle(tone == .stop ? Theme.alert : Theme.ink)
            if let message {
                Text(message)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Theme.caption.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 2)
                    .minimumHitArea()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.rowPaddingH)
        .themedCard(radius: Theme.radiusBanner)
        .accessibilityElement(children: .contain)
    }
}

/// A brief copy acknowledgement. No modal, and it fades unless Reduce Motion is
/// on, in which case it simply appears and disappears.
struct Toast: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.label.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(Theme.onInk)
            .padding(.horizontal, Theme.textInset)
            .padding(.vertical, 12)
            .background(Theme.ink, in: Capsule())
            .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Tags (B 词签)

/// The tag selector.
///
/// A native adaptive grid at ordinary sizes; at accessibility sizes it falls
/// back to a native checkmark list with the same data, the same 3/3 rule and the
/// same hint copy. That fallback is an accepted accessibility outcome, not a
/// change to tag semantics — and there is no bespoke flow-layout framework
/// either way.
struct TagChipGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let tags: [String]
    let isSelected: (String) -> Bool
    let canToggle: (String) -> Bool
    let toggle: (String) -> Void
    var isEnabled = true

    private var usesListFallback: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        if usesListFallback {
            VStack(spacing: 0) {
                ForEach(Array(tags.enumerated()), id: \.element) { index, tag in
                    if index > 0 { RowDivider() }
                    listRow(tag)
                }
            }
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 88), spacing: 10)],
                spacing: 10
            ) {
                ForEach(tags, id: \.self) { tag in chip(tag) }
            }
            .padding(Theme.rowPaddingH)
        }
    }

    private func listRow(_ tag: String) -> some View {
        Button {
            toggle(tag)
        } label: {
            HStack {
                Text(tag)
                    .font(Theme.row)
                    .foregroundStyle(rowForeground(tag))
                Spacer()
                if isSelected(tag) {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                }
            }
            .frame(minHeight: Theme.rowMinHeight)
            .padding(.horizontal, Theme.rowPaddingH)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled || !canToggle(tag))
        .accessibilityValue(accessibilityValue(tag))
    }

    private func chip(_ tag: String) -> some View {
        let selected = isSelected(tag)
        let selectable = isEnabled && canToggle(tag)
        return Button {
            toggle(tag)
        } label: {
            HStack(spacing: 4) {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                }
                Text(tag)
                    .font(Theme.chip)
                    .lineLimit(1)
            }
            .foregroundStyle(chipForeground(selected: selected, selectable: selectable))
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(chipBackground(selected: selected, selectable: selectable))
            .overlay(chipStroke(selected: selected, selectable: selectable))
            .minimumHitArea()
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityValue(accessibilityValue(tag))
    }

    private func chipForeground(selected: Bool, selectable: Bool) -> Color {
        if selected { return Theme.onInk }
        return selectable ? Theme.ink : Theme.textTertiary
    }

    @ViewBuilder
    private func chipBackground(selected: Bool, selectable: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
        if selected {
            shape.fill(Theme.ink)
        } else if selectable {
            shape.fill(Theme.surface)
        } else {
            shape.fill(Theme.surfaceMuted)
        }
    }

    @ViewBuilder
    private func chipStroke(selected: Bool, selectable: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radiusChip, style: .continuous)
        if selected {
            EmptyView()
        } else if selectable {
            shape.strokeBorder(Theme.separator, lineWidth: Theme.hairline)
        } else {
            // Shape *and* text carry the disabled meaning, never color alone.
            shape.strokeBorder(
                Theme.textTertiary,
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
        }
    }

    private func rowForeground(_ tag: String) -> Color {
        (isEnabled && canToggle(tag)) ? Theme.ink : Theme.textTertiary
    }

    private func accessibilityValue(_ tag: String) -> String {
        if isSelected(tag) { return "已选择" }
        return canToggle(tag) ? "未选择" : "已达上限，不可选"
    }
}
