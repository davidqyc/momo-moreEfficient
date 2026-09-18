import SwiftUI

/// The 方案一「墨与米」 design roles.
///
/// Semantic roles only. Views reference `Theme.ink`, never a hex literal: the
/// actual values live in the asset catalog with Any / Dark / Increased-Contrast
/// variants, so dark mode and high contrast are the catalog's job rather than
/// per-screen branching.
///
/// The only saturated color in the family is `accent`, and it never carries
/// meaning on its own — every state that matters also differs in glyph, text or
/// weight. Success is ink with a ✓, never green.
enum Theme {
    // MARK: Colors

    /// Primary text, primary action fills, selected chips.
    static let ink = Color("InkPrimary")
    /// Label on an ink-filled surface.
    static let onInk = Color("OnInk")
    /// Label on the coral accent.
    static let onAccent = Color("OnAccent")
    /// Screen background.
    static let canvas = Color("Canvas")
    /// Card / grouped-row background.
    static let surface = Color("Surface")
    /// Segment tracks, alternate fills.
    static let surfaceMuted = Color("SurfaceMuted")
    static let separator = Color("Separator")
    static let textSecondary = Color("TextSecondary")
    /// Placeholders, chevrons, queued `···`.
    static let textTertiary = Color("TextTertiary")
    /// The one saturated color. Selection and attention only, never text.
    static let accent = Color("AccentCoral")
    /// Error text, 无法读取, destructive labels.
    static let alert = Color("AlertInk")
    static let disabledFill = Color("DisabledFill")
    static let disabledText = Color("DisabledText")
    /// The 需重新预览 row tint.
    static let staleTint = Color("StaleTint")

    // MARK: Spacing / radius

    /// Card insets from the screen edge.
    static let pageMargin: CGFloat = 16
    /// Titles, group labels, status lines.
    static let textInset: CGFloat = 20
    static let rowPaddingH: CGFloat = 18
    static let rowMinHeight: CGFloat = 54
    static let controlHeight: CGFloat = 56
    static let gapS: CGFloat = 8
    static let gapM: CGFloat = 13
    static let gapL: CGFloat = 23

    static let radiusScreenCard: CGFloat = 22
    static let radiusBanner: CGFloat = 16
    static let radiusTile: CGFloat = 28
    static let radiusPill: CGFloat = 22
    static let radiusChip: CGFloat = 16
    static let hairline: CGFloat = 1

    /// The minimum tappable size, everywhere.
    static let minimumTarget: CGFloat = 44

    // MARK: Typography

    /// Page titles. A large-title feel without the system large title.
    static let pageTitle = Font.title.weight(.semibold)
    static let navTitle = Font.headline
    static let tileTitle = Font.title3.weight(.semibold)
    static let row = Font.body
    static let rowValue = Font.subheadline
    static let body = Font.subheadline
    static let label = Font.footnote
    static let caption = Font.caption
    static let chip = Font.subheadline.weight(.medium)
    static let primaryButton = Font.headline
    /// All counts, progress and cells use tabular figures so columns align.
    static let digits = Font.body.monospacedDigit()
}

extension View {
    /// The standard screen background.
    func themedScreen() -> some View {
        background(Theme.canvas.ignoresSafeArea())
    }

    /// A card surface with the family's hairline stroke.
    func themedCard(radius: CGFloat = Theme.radiusScreenCard) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: Theme.hairline)
            )
    }

    /// Expands a small visual control to a full 44pt hit area.
    func minimumHitArea() -> some View {
        contentShape(Rectangle())
            .frame(minWidth: Theme.minimumTarget, minHeight: Theme.minimumTarget)
    }
}
