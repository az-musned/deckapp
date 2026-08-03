import SwiftUI

enum GlassProminence {
    case subtle
    case interactive
    case elevated

    var fallbackMaterial: Material {
        switch self {
        case .subtle: .ultraThinMaterial
        case .interactive: .thinMaterial
        case .elevated: .regularMaterial
        }
    }
}

struct GlassSurfaceModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    let prominence: GlassProminence
    let cornerRadius: CGFloat
    let tint: Color?
    let isInteractive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency, contrast != .increased {
            content
                .glassEffect(
                    .regular.tint(tint).interactive(isInteractive),
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
        } else {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            reduceTransparency
                                ? AnyShapeStyle(Color(uiColor: .secondarySystemBackground))
                                : AnyShapeStyle(prominence.fallbackMaterial)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(DesignToken.Color.cardBorder, lineWidth: contrast == .increased ? 1.5 : 0.75)
                        }
                }
        }
    }
}

extension View {
    func glassSurface(
        _ prominence: GlassProminence = .interactive,
        cornerRadius: CGFloat = DesignToken.Radius.card,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(
            GlassSurfaceModifier(
                prominence: prominence,
                cornerRadius: cornerRadius,
                tint: tint,
                isInteractive: interactive
            )
        )
    }
}

struct LiquidGlassContainer<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = DesignToken.Spacing.medium, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
