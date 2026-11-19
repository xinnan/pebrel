import SwiftUI

enum GlassTier {
    case bar
    case heavy
    case light
}

struct GlassSurfaceModifier: ViewModifier {
    @Environment(\.pebrelPalette) private var palette
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let tier: GlassTier
    let cornerRadius: CGFloat
    let accent: Color?

    private var useSolid: Bool {
        reduceTransparency || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func solvedAlpha(base: Double, fallback: Double) -> Double {
        if useSolid { return fallback }
        let tintRGB = palette.isDark
            ? PebrelPalette.lerp(palette.bgRGB, palette.fgRGB, t: 0.05)
            : PebrelPalette.lerp(palette.bgRGB, (1, 1, 1), t: 0.72)
        let backdrop = PebrelPalette.lerp(palette.bgRGB, palette.fgRGB, t: 0.5)
        var alpha = base
        while alpha < 0.98 {
            let composited = PebrelPalette.lerp(backdrop, tintRGB, t: alpha)
            let primaryContrast = PebrelPalette.contrastRatio(palette.fgRGB, composited)
            let mutedContrast = PebrelPalette.contrastRatio(palette.mutedRGB, composited)
            if primaryContrast >= 4.5 && mutedContrast >= 3.0 {
                return alpha
            }
            alpha += 0.02
        }
        return 0.96
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let fillTint: Color = {
            if let accent {
                return accent.opacity(useSolid ? 1.0 : 0.88)
            }
            switch tier {
            case .bar:
                return palette.surface.opacity(solvedAlpha(base: 0.84, fallback: 0.96))
            case .heavy:
                return palette.surface.opacity(solvedAlpha(base: palette.isDark ? 0.84 : 0.82, fallback: 0.96))
            case .light:
                return palette.surface.opacity(solvedAlpha(base: palette.isDark ? 0.58 : 0.54, fallback: 0.90))
            }
        }()

        let hairlineColor = palette.foreground.opacity(palette.isDark ? 0.16 : 0.12)

        content
            .background {
                if useSolid {
                    shape.fill(fillTint)
                } else {
                    ZStack {
                        shape.fill(tier == .light ? Material.ultraThinMaterial : Material.regularMaterial)
                        shape.fill(fillTint)
                    }
                }
            }
            .overlay {
                if cornerRadius > 0 {
                    shape.strokeBorder(hairlineColor, lineWidth: 0.5)
                }
            }
            .clipShape(shape)
    }
}

extension View {
    func pebrelGlass(tier: GlassTier = .heavy, cornerRadius: CGFloat = 18, accent: Color? = nil) -> some View {
        modifier(GlassSurfaceModifier(tier: tier, cornerRadius: cornerRadius, accent: accent))
    }

    func pebrelGlassBar() -> some View {
        modifier(GlassSurfaceModifier(tier: .bar, cornerRadius: 0, accent: nil))
    }
}

/// Shared navigation bar header following Apple HIG + Pebrel Mobile DESIGN.md geometry.
struct PebrelPageHeader<Trailing: View>: View {
    @Environment(\.pebrelPalette) private var palette

    let title: String
    let subtitle: String?
    let onBack: (() -> Void)?
    @ViewBuilder let trailing: () -> Trailing

    init(
        _ title: String,
        subtitle: String? = nil,
        onBack: (() -> Void)? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.onBack = onBack
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.tr("back"))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.muted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 54)
        .pebrelGlassBar()
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.outlineVariant)
                .frame(height: 0.5)
        }
    }
}

extension PebrelPageHeader where Trailing == EmptyView {
    init(_ title: String, subtitle: String? = nil, onBack: (() -> Void)? = nil) {
        self.init(title, subtitle: subtitle, onBack: onBack, trailing: { EmptyView() })
    }
}
