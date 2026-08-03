import SwiftUI

struct SidebarNavigation: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: AppSection

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Spacing.large) {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("My Room")
                        .font(.title3.bold())
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                Text("Control Center")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LiquidGlassContainer(spacing: DesignToken.Spacing.xSmall) {
                VStack(spacing: DesignToken.Spacing.xSmall) {
                    ForEach(AppSection.allCases) { section in
                        Button {
                            selection = section
                        } label: {
                            Label(section.title, systemImage: section.symbol)
                                .font(.subheadline.weight(selection == section ? .semibold : .regular))
                                .foregroundStyle(selection == section ? DesignToken.Color.accent : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, DesignToken.Spacing.medium)
                                .padding(.vertical, DesignToken.Spacing.small)
                        }
                        .buttonStyle(.plain)
                        .background {
                            if selection == section {
                                RoundedRectangle(cornerRadius: DesignToken.Radius.control)
                                    .fill(DesignToken.Color.accent.opacity(0.13))
                            }
                        }
                        .contentShape(Rectangle())
                    }
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: DesignToken.Spacing.small) {
                Text("System Status")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Label("Home Assistant", systemImage: "house.and.flag")
                HStack {
                    Label("Companion", systemImage: "desktopcomputer")
                    Spacer()
                    Circle()
                        .fill(companionStatusColor)
                        .frame(width: 7, height: 7)
                }
                Divider()
                Label("All systems normal", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(DesignToken.Color.positive)
            }
            .font(.caption)
        }
        .padding(DesignToken.Spacing.large)
        .glassSurface(.elevated, cornerRadius: DesignToken.Radius.panel)
    }

    private var companionStatusColor: Color {
        if case .connected = appState.companionStatus {
            DesignToken.Color.positive
        } else {
            .secondary
        }
    }
}
