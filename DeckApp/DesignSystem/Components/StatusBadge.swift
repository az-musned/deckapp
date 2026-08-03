import SwiftUI

struct GlassConnectionBadge: View {
    let route: ConnectionRoute

    private var color: Color {
        switch route {
        case .local: DesignToken.Color.positive
        case .remote: DesignToken.Color.cyan
        case .offline: .secondary
        }
    }

    var body: some View {
        Label(route.rawValue, systemImage: route == .offline ? "wifi.slash" : "network")
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, DesignToken.Spacing.small)
            .padding(.vertical, DesignToken.Spacing.xSmall)
            .glassSurface(.interactive, cornerRadius: 999, tint: color.opacity(0.22))
            .accessibilityLabel("Connection: \(route.rawValue)")
    }
}

struct CommandStatusPill: View {
    let status: CommandStatus

    private var color: Color {
        switch status {
        case .pending, .queued, .running: DesignToken.Color.warning
        case .confirmed: DesignToken.Color.positive
        case .failed: DesignToken.Color.destructive
        case .unavailable: .secondary
        }
    }

    var body: some View {
        HStack(spacing: DesignToken.Spacing.xSmall) {
            if status == .pending || status == .queued || status == .running {
                ProgressView().controlSize(.small).tint(color)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(status.rawValue.capitalized)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, DesignToken.Spacing.small)
        .padding(.vertical, DesignToken.Spacing.xSmall)
        .glassSurface(.interactive, cornerRadius: 999, tint: color.opacity(0.18))
    }
}
