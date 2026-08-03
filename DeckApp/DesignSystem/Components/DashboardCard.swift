import SwiftUI

struct DashboardCard<Content: View>: View {
    var title: String?
    var symbol: String?
    @ViewBuilder let content: Content

    init(title: String? = nil, symbol: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Spacing.medium) {
            if let title {
                Label(title, systemImage: symbol ?? "circle")
                    .font(.headline)
                    .foregroundStyle(.primary)
            }
            content
        }
        .padding(DesignToken.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: DesignToken.Radius.card, style: .continuous)
                .fill(DesignToken.Color.card)
                .overlay {
                    RoundedRectangle(cornerRadius: DesignToken.Radius.card, style: .continuous)
                        .strokeBorder(DesignToken.Color.cardBorder, lineWidth: 0.75)
                }
        }
    }
}
