import SwiftUI

struct GlassIcon: View {
    let symbol: String
    var tint: Color = DesignToken.Color.accent
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: Circle())
            .overlay(Circle().strokeBorder(tint.opacity(0.3), lineWidth: 0.75))
            .shadow(color: tint.opacity(0.28), radius: 12)
    }
}
