import SwiftUI

struct GlassActionButton: View {
    let title: String
    let symbol: String
    var tint: Color = DesignToken.Color.accent
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role) {
            RemoteHaptics.heavy()
            action()
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, DesignToken.Spacing.small)
                .contentShape(Rectangle())
        }
        .buttonStyle(AdaptiveGlassButtonStyle(tint: tint))
    }
}

private struct AdaptiveGlassButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .glassSurface(.interactive, cornerRadius: DesignToken.Radius.control, tint: tint.opacity(0.22), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(reduceMotion ? nil : DesignToken.Animation.responsive, value: configuration.isPressed)
    }
}
