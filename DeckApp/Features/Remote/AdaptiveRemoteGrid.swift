import SwiftUI

/// Standardizes the adaptive column sizing/spacing shared by the PC and TV remotes'
/// flat button collections, so both use the same tile rhythm.
struct AdaptiveRemoteGrid<Item: Identifiable, ItemContent: View>: View {
    let items: [Item]
    var minimumTileWidth: CGFloat = 130
    var minimumTileHeight: CGFloat = 68
    @ViewBuilder var content: (Item) -> ItemContent

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimumTileWidth), spacing: DesignToken.Spacing.medium)]) {
            ForEach(items) { item in
                content(item)
                    .frame(minHeight: minimumTileHeight)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
