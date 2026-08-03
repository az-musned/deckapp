import SwiftUI

struct IntegrationHealthView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ForEach(appState.integrationHealthItems) { item in
            HStack(alignment: .top, spacing: DesignToken.Spacing.small) {
                Image(systemName: item.symbol)
                    .foregroundStyle(color(for: item.level))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(item.title).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(item.status).font(.caption.weight(.semibold)).foregroundStyle(color(for: item.level))
                    }
                    Text(item.detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        Text("Diagnostics never include credentials, typed data, entity identifiers, or configured URLs.")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    private func color(for level: IntegrationHealthLevel) -> Color {
        switch level {
        case .healthy: DesignToken.Color.positive
        case .attention: DesignToken.Color.warning
        case .unavailable: DesignToken.Color.destructive
        case .informational: .secondary
        }
    }
}
