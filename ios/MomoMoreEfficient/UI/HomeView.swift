import SwiftUI

/// 首页乙 — the frozen ivory-dominant Home.
///
/// Exactly four entries and nothing else: no account row, no History summary,
/// no metrics, no recent activity, no bottom tab bar. Capture never appears
/// here; it arrives as a modal from the system share sheet.
struct HomeView: View {
    /// The two work tiles select the initial `ContentMode` and then enter the
    /// one `.write` destination — the mode is view-model state, not a route.
    let onEnterWrite: (ContentMode) -> Void
    let onEnterQuery: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.gapL) {
                header

                section(
                    marker: .filled,
                    title: "录入 · 释义与例句"
                ) {
                    HStack(spacing: 12) {
                        HomeTile(
                            title: "释义录入",
                            lines: ["拼写 + 释义", "预览后写入"]
                        ) {
                            onEnterWrite(.interpretation)
                        }
                        HomeTile(
                            title: "例句录入",
                            lines: ["例句 + 翻译", "预览后写入"]
                        ) {
                            onEnterWrite(.phrase)
                        }
                    }
                }

                section(
                    marker: .hollow,
                    title: "查阅 · 只读取，不写入"
                ) {
                    QueryCard(action: onEnterQuery)
                }

                Spacer(minLength: Theme.gapL)
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.top, Theme.gapS)
        }
        .themedScreen()
    }

    private var header: some View {
        HStack {
            Text("小黑鸟伴侣")
                .font(Theme.navTitle)
                .foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            NavPill(title: "设置", action: onOpenSettings)
        }
        .padding(.top, Theme.gapS)
    }

    private enum SectionMarker { case filled, hollow }

    @ViewBuilder
    private func section<Content: View>(
        marker: SectionMarker,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.gapM) {
            HStack(spacing: 6) {
                Group {
                    if marker == .filled {
                        Circle().fill(Theme.accent)
                    } else {
                        Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.5)
                    }
                }
                .frame(width: 7, height: 7)
                Text(title)
                    .font(Theme.label)
                    .foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

/// One of the two ink work tiles.
private struct HomeTile: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let title: String
    let lines: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.gapS) {
                Text(title)
                    .font(Theme.tileTitle)
                    .foregroundStyle(Theme.onInk)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(Theme.caption)
                            .foregroundStyle(Theme.onInk.opacity(0.72))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.gapM)
                HStack {
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.onInk)
                        .frame(width: 30, height: 30)
                        .background(Theme.onInk.opacity(0.14), in: Circle())
                }
            }
            .padding(Theme.textInset)
            .frame(maxWidth: .infinity, minHeight: tileHeight, alignment: .topLeading)
            .background(
                Theme.ink,
                in: RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        // The name leads; the supporting lines are the value, so VoiceOver
        // announces "释义录入" rather than one run-on phrase.
        .accessibilityLabel(title)
        .accessibilityValue(lines.joined(separator: "，"))
    }

    /// Tiles grow rather than truncate under larger type.
    private var tileHeight: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 150 : 196
    }
}

/// The ivory 批量查阅 card.
private struct QueryCard: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.gapM) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("批量查阅")
                        .font(Theme.tileTitle)
                        .foregroundStyle(Theme.ink)
                    Text("一批词各有多少释义 / 例句 / 助记，只读取不写入")
                        .font(Theme.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.gapS)
                Image(systemName: "arrow.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.onInk)
                    .frame(width: 34, height: 34)
                    .background(Theme.ink, in: Circle())
            }
            .padding(Theme.textInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(radius: Theme.radiusTile)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("批量查阅")
        .accessibilityValue("一批词各有多少释义 / 例句 / 助记，只读取不写入")
    }
}
