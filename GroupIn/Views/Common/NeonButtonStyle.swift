//
//  NeonButtonStyle.swift
//  GroupIn
//
//  The GroupIn button kit. One control language shared across every
//  surface so buttons stop looking hand-rolled.
//
//  On iOS 26+ this is Apple's **Liquid Glass** — translucent, tintable,
//  interactive system glass (`.glassEffect`) per the 2026 design
//  guidelines. On iOS 17.6–25 it falls back to a light, restrained
//  material capsule (no heavy strokes or glows) so older devices still
//  look clean and consistent.
//
//  Styles (call sites are identical across OS versions):
//    • .neon / .neonSecondary — clear glass with a brand-cyan label.
//      Deliberately the SAME feeling everywhere — no loud prominent
//      fill — so no single button reads as a "different color" action.
//    • .neonDestructive — clear glass, red label.
//    • .neonCard        — glass frame for rich tappable rows.
//    • .neonIcon        — circular glass icon button.
//
//  Each carries a `tint` (default `.accentColor`) so member-colored
//  contexts can pass that friend's color and stay on-brand.
//

import SwiftUI

// MARK: - Shared tokens

private enum NeonButtonMetrics {
    static let cardCornerRadius: CGFloat = 24
    static let verticalPadding: CGFloat = 16
    static let horizontalPadding: CGFloat = 22
    static let cardVerticalPadding: CGFloat = 12
    static let cardHorizontalPadding: CGFloat = 16
    static let pressedScale: CGFloat = 0.97
    static let strokeWidth: CGFloat = 1
}

// MARK: - Pill / capsule style

struct NeonButtonStyle: ButtonStyle {
    enum Role {
        case primary
        case secondary
        case destructive
    }

    var role: Role = .primary
    var tint: Color = .accentColor
    var fullWidth: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration,
                    role: role,
                    tint: tint,
                    fullWidth: fullWidth)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let role: Role
        let tint: Color
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            // `.contentShape` declares the hit-test region. Without it,
            // SwiftUI only routes taps that land on the actual label
            // glyphs — the padded capsule surrounding the text is
            // visually a button but isn't touch-active, so users have
            // to hit the text precisely. Declaring the capsule as the
            // hit shape matches the painted background exactly, gives
            // the full button surface a tap target (Apple HIG: 44pt
            // minimum, easily met by the padded capsule), and is the
            // 2026 best-practice pairing with `.glassEffect`/`Capsule`
            // backgrounds. Purely a hit-test change — no pixel moves.
            let base = configuration.label
                .font(.body.weight(.semibold))
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .padding(.vertical, NeonButtonMetrics.verticalPadding)
                .padding(.horizontal, NeonButtonMetrics.horizontalPadding)
                .foregroundStyle(foreground)
                .contentShape(Capsule())

            if #available(iOS 26.0, *) {
                // Every button is the SAME clear interactive glass — no
                // prominent tinted fill — so nothing reads as a louder
                // "different color" action. Brand cyan lives in the
                // label; danger is a red label.
                base
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .opacity(isEnabled ? 1 : 0.45)
            } else {
                base
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(legacyStroke,
                                                    lineWidth: NeonButtonMetrics.strokeWidth))
                    .opacity(isEnabled ? 1 : 0.5)
                    .scaleEffect(configuration.isPressed ? NeonButtonMetrics.pressedScale : 1)
                    .animation(.smooth(duration: 0.15), value: configuration.isPressed)
            }
        }

        /// Brand cyan for normal actions, red for destructive — the only
        /// thing that varies between buttons; the glass is identical.
        private var foreground: Color {
            guard isEnabled else { return .secondary }
            return role == .destructive ? .red : tint
        }

        private var legacyStroke: Color {
            guard isEnabled else { return Color.gray.opacity(0.3) }
            return (role == .destructive ? Color.red : tint).opacity(0.4)
        }
    }
}

// MARK: - Card style (rich custom content)

/// The same glass language as `.neon`, but it wraps arbitrary content
/// (an avatar, multi-line text, a chevron) rather than a centered
/// label. Use it for tappable "cards" like the Home profile row so
/// they read as siblings of the neon buttons beside them.
struct NeonCardButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    /// Retained for source compatibility; glass needs no extra glow.
    var glow: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        StyledCard(configuration: configuration, tint: tint)
    }

    private struct StyledCard: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let shape = RoundedRectangle(
                cornerRadius: NeonButtonMetrics.cardCornerRadius,
                style: .continuous
            )
            let base = configuration.label
                .padding(.vertical, NeonButtonMetrics.cardVerticalPadding)
                .padding(.horizontal, NeonButtonMetrics.cardHorizontalPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Use the SAME rounded-rect shape that paints the card
                // background as the hit region. Without this, tapping
                // the empty gutter between an avatar and the chevron
                // (the dominant gesture target on the Home group rows)
                // fails silently because only the avatar/text/chevron
                // glyphs are hit-tested. Matches the visible card
                // exactly; no appearance change.
                .contentShape(shape)

            if #available(iOS 26.0, *) {
                base
                    .glassEffect(.regular.interactive(), in: shape)
                    .opacity(isEnabled ? 1 : 0.45)
            } else {
                base
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.12),
                                                lineWidth: NeonButtonMetrics.strokeWidth))
                    .scaleEffect(configuration.isPressed ? 0.98 : 1)
                    .animation(.smooth(duration: 0.15), value: configuration.isPressed)
            }
        }
    }
}

// MARK: - Circular icon style

struct NeonIconButtonStyle: ButtonStyle {
    var tint: Color = .accentColor
    var diameter: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint, diameter: diameter)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        let diameter: CGFloat
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let base = configuration.label
                .font(.body.weight(.semibold))
                .frame(width: diameter, height: diameter)
                // SF Symbols are smaller than the surrounding 44pt
                // frame, so without a circular hit shape the user can
                // only tap the glyph pixels — the dead ring around the
                // icon (visually part of the glass disc) ignores taps.
                // Matches the painted Circle background exactly.
                .contentShape(Circle())

            if #available(iOS 26.0, *) {
                base
                    .foregroundStyle(tint)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .opacity(isEnabled ? 1 : 0.45)
            } else {
                base
                    .foregroundStyle(isEnabled ? tint : .secondary)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(tint.opacity(0.5),
                                                   lineWidth: NeonButtonMetrics.strokeWidth))
                    .scaleEffect(configuration.isPressed ? 0.92 : 1)
                    .animation(.smooth(duration: 0.15), value: configuration.isPressed)
            }
        }
    }
}

// MARK: - Ergonomic factories

extension ButtonStyle where Self == NeonButtonStyle {
    /// Primary glass action. Brand cyan by default.
    static var neon: NeonButtonStyle { NeonButtonStyle(role: .primary) }

    /// Primary action tinted to a specific color (e.g. a member color).
    static func neon(tint: Color, fullWidth: Bool = true) -> NeonButtonStyle {
        NeonButtonStyle(role: .primary, tint: tint, fullWidth: fullWidth)
    }

    /// Neutral clear-glass companion to a `.neon` primary.
    static var neonSecondary: NeonButtonStyle {
        NeonButtonStyle(role: .secondary)
    }

    /// Red glass for destructive actions.
    static var neonDestructive: NeonButtonStyle {
        NeonButtonStyle(role: .destructive)
    }
}

extension ButtonStyle where Self == NeonCardButtonStyle {
    /// Glass card frame for tappable rows with rich content.
    static var neonCard: NeonCardButtonStyle { NeonCardButtonStyle() }

    static func neonCard(tint: Color, glow: Bool = true) -> NeonCardButtonStyle {
        NeonCardButtonStyle(tint: tint, glow: glow)
    }
}

extension ButtonStyle where Self == NeonIconButtonStyle {
    static var neonIcon: NeonIconButtonStyle { NeonIconButtonStyle() }

    static func neonIcon(tint: Color, diameter: CGFloat = 44) -> NeonIconButtonStyle {
        NeonIconButtonStyle(tint: tint, diameter: diameter)
    }
}

#Preview {
    VStack(spacing: 20) {
        Button("Create a Group") {}.buttonStyle(.neon)
        Button("Join a Group") {}.buttonStyle(.neonSecondary)
        Button("Leave Group") {}.buttonStyle(.neonDestructive)
        Button("Disabled") {}.buttonStyle(.neon).disabled(true)
        Button { } label: {
            HStack(spacing: 12) {
                Circle().fill(.cyan).frame(width: 40, height: 40)
                VStack(alignment: .leading) {
                    Text("Kian").font(.headline)
                    Text("Edit profile").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.neonCard)
        HStack(spacing: 16) {
            Button { } label: { Image(systemName: "bubble.left.and.bubble.right.fill") }
                .buttonStyle(.neonIcon)
            Button { } label: { Image(systemName: "scope") }
                .buttonStyle(.neonIcon(tint: .green))
        }
    }
    .padding(32)
}
