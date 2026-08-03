import SwiftUI

struct PlaceholderFeatureView: View {
    let section: AppSection

    var body: some View {
        VStack(spacing: DesignToken.Spacing.large) {
            GlassIcon(symbol: section.symbol, size: 68)
            Text(section.title)
                .font(.largeTitle.bold())
            Text("This feature will use Home Assistant-backed services in the next implementation phase.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(DesignToken.Spacing.xLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
