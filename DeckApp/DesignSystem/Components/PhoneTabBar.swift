import SwiftUI

struct PhoneTabBar: View {
    @Binding var selection: AppSection

    private let sections: [AppSection] = [.dashboard, .remote, .climate, .scenes, .settings]

    var body: some View {
        GeometryReader { proxy in
            let innerWidth = max(proxy.size.width - (DesignToken.Spacing.xSmall * 2), 0)
            let itemWidth = innerWidth / CGFloat(sections.count)

            LiquidGlassContainer(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(sections) { section in
                        Button {
                            selection = section
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: section.symbol)
                                    .font(.system(size: 17, weight: .semibold))
                                Text(section == .settings ? "More" : section.title)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .foregroundStyle(selection == section ? DesignToken.Color.accent : .primary)
                            .frame(width: itemWidth)
                            .padding(.vertical, DesignToken.Spacing.xSmall)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background {
                            if selection == section {
                                RoundedRectangle(cornerRadius: DesignToken.Radius.control, style: .continuous)
                                    .fill(DesignToken.Color.accent.opacity(0.13))
                            }
                        }
                        .accessibilityLabel(section == .settings ? "More" : section.title)
                        .accessibilityAddTraits(selection == section ? .isSelected : [])
                    }
                }
                .padding(DesignToken.Spacing.xSmall)
                .glassSurface(.elevated, cornerRadius: DesignToken.Radius.card)
            }
        }
        .frame(height: 62)
    }
}
