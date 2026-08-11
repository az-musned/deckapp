import SwiftUI

/// Shared header layout for the PC and TV remotes: a title, a colored status row,
/// and a trailing row of actions. Keeping this in one place is what makes the two
/// remotes read as one control surface instead of two unrelated screens.
struct RemoteHeaderBar<Trailing: View>: View {
    let title: String
    let statusColor: Color
    let statusText: String
    var statusDetail: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: DesignToken.Spacing.medium) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.bold())
                HStack(spacing: DesignToken.Spacing.xSmall) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(statusText)
                    if let statusDetail {
                        Text("· \(statusDetail)")
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
            }
            Spacer()
            trailing()
        }
    }
}

/// The bare glyph used inside a circular remote header action, shared so a plain
/// button and a Menu label render identically.
struct RemoteIconGlyph: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .frame(width: 38, height: 38)
    }
}

/// A circular glass icon button, matching the style every remote header action uses.
struct RemoteIconButton: View {
    let symbol: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RemoteIconGlyph(symbol: symbol)
        }
        .buttonStyle(.plain)
        .glassSurface(.interactive, cornerRadius: 999, interactive: true)
        .accessibilityLabel(accessibilityLabel)
    }
}
