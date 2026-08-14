import SwiftUI

struct SidebarNavigation: View {
    @Environment(AppState.self) private var appState
    @Binding var selection: AppSection
    @Binding var isCollapsed: Bool

    var body: some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: DesignToken.Spacing.medium) {
            header
            navigationItems
            Spacer(minLength: DesignToken.Spacing.small)
            if !isCollapsed { systemStatus }
            collapseButton
        }
        .padding(.horizontal, isCollapsed ? DesignToken.Spacing.small : DesignToken.Spacing.large)
        .padding(.vertical, DesignToken.Spacing.large)
        .glassSurface(.elevated, cornerRadius: DesignToken.Radius.panel)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var header: some View {
        if isCollapsed {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(DesignToken.Color.accent)
                .frame(maxWidth: .infinity, minHeight: 34)
                .accessibilityLabel("My Room Control Center")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("My Room")
                        .font(.title3.bold())
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                Text("Control Center")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var navigationItems: some View {
        LiquidGlassContainer(spacing: DesignToken.Spacing.xSmall) {
            VStack(spacing: DesignToken.Spacing.xSmall) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        HStack(spacing: DesignToken.Spacing.medium) {
                            Image(systemName: section.symbol)
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 26)
                            if !isCollapsed {
                                Text(section.title)
                                    .font(.system(size: 16, weight: selection == section ? .semibold : .regular))
                                    .lineLimit(1)
                            }
                        }
                        .foregroundStyle(selection == section ? DesignToken.Color.accent : .primary)
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: isCollapsed ? .center : .leading)
                        .padding(.horizontal, isCollapsed ? 0 : DesignToken.Spacing.small)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if selection == section {
                            RoundedRectangle(cornerRadius: DesignToken.Radius.control)
                                .fill(DesignToken.Color.accent.opacity(0.13))
                        }
                    }
                    .accessibilityLabel(section.title)
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                }
            }
        }
    }

    private var systemStatus: some View {
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
        .transition(.opacity)
    }

    private var collapseButton: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            HStack(spacing: DesignToken.Spacing.small) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 19, weight: .semibold))
                if !isCollapsed {
                    Text("Minimize")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.left")
                        .font(.caption.weight(.bold))
                }
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: isCollapsed ? .center : .leading)
            .padding(.horizontal, isCollapsed ? 0 : DesignToken.Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassSurface(.subtle, cornerRadius: DesignToken.Radius.control, interactive: true)
        .accessibilityLabel(isCollapsed ? "Expand sidebar" : "Minimize sidebar")
    }

    private var companionStatusColor: Color {
        if case .connected = appState.companionStatus {
            DesignToken.Color.positive
        } else {
            .secondary
        }
    }
}
