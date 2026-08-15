import SwiftUI

struct RoomControlGrid: View {
    let template: RoomControlTemplate
    let columnCount: Int
    let layoutClass: RoomWidgetLayoutClass

    var body: some View {
        VStack(alignment: .leading, spacing: DesignToken.Spacing.medium) {
            ForEach(Self.rows(for: resolvedWidgets, columns: columnCount)) { row in
                RoomWidgetSpanRowLayout(
                    columns: columnCount,
                    spans: row.items.map(\.span),
                    spacing: DesignToken.Spacing.medium
                ) {
                    ForEach(row.items) { placement in
                        RoomControlWidgetView(definition: placement.widget, compact: columnCount == 2)
                            .frame(
                                maxWidth: .infinity,
                                minHeight: minimumHeight(for: placement.widget),
                                maxHeight: .infinity,
                                alignment: .topLeading
                            )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func minimumHeight(for widget: RoomWidgetDefinition) -> CGFloat {
        if layoutClass == .pad, widget.kind == .audioMixer {
            return max(widget.size.minimumHeight, 252)
        }
        return widget.size.minimumHeight
    }

    private var resolvedWidgets: [RoomWidgetDefinition] {
        template.widgets.map { widget in
            var resolved = widget
            resolved.size = widget.resolvedSize(for: layoutClass)
            return resolved
        }
    }

    static func rows(for widgets: [RoomWidgetDefinition], columns: Int) -> [RoomWidgetGridRow] {
        let safeColumns = max(columns, 1)
        var rows: [RoomWidgetGridRow] = []
        var current: [RoomWidgetPlacement] = []
        var usedColumns = 0

        for widget in widgets {
            let span = min(widget.size.columnSpan(in: safeColumns), safeColumns)
            if usedColumns + span > safeColumns, !current.isEmpty {
                rows.append(RoomWidgetGridRow(items: current))
                current = []
                usedColumns = 0
            }

            current.append(RoomWidgetPlacement(widget: widget, span: span))
            usedColumns += span

            if usedColumns == safeColumns {
                rows.append(RoomWidgetGridRow(items: current))
                current = []
                usedColumns = 0
            }
        }

        if !current.isEmpty {
            rows.append(RoomWidgetGridRow(items: current))
        }
        return rows
    }
}

/// A width-constrained row for dashboard widgets that span logical columns.
/// Unlike `Grid`, child content can never increase the row beyond its proposal.
private struct RoomWidgetSpanRowLayout: Layout {
    let columns: Int
    let spans: [Int]
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let proposedWidth = max(proposal.width ?? 0, 0)
        let cellWidth = widthPerColumn(totalWidth: proposedWidth)
        let height = subviews.enumerated().reduce(CGFloat.zero) { result, entry in
            let itemWidth = width(for: span(at: entry.offset), cellWidth: cellWidth)
            let size = entry.element.sizeThatFits(ProposedViewSize(width: itemWidth, height: nil))
            return max(result, size.height)
        }
        return CGSize(width: proposedWidth, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let cellWidth = widthPerColumn(totalWidth: bounds.width)
        var usedColumns = 0

        for (index, subview) in subviews.enumerated() {
            let span = span(at: index)
            let itemWidth = width(for: span, cellWidth: cellWidth)
            let x = bounds.minX + CGFloat(usedColumns) * (cellWidth + spacing)
            subview.place(
                at: CGPoint(x: x, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: itemWidth, height: bounds.height)
            )
            usedColumns += span
        }
    }

    private func span(at index: Int) -> Int {
        min(max(spans.indices.contains(index) ? spans[index] : 1, 1), max(columns, 1))
    }

    private func widthPerColumn(totalWidth: CGFloat) -> CGFloat {
        let safeColumns = max(columns, 1)
        let interColumnSpacing = spacing * CGFloat(safeColumns - 1)
        return max((totalWidth - interColumnSpacing) / CGFloat(safeColumns), 0)
    }

    private func width(for span: Int, cellWidth: CGFloat) -> CGFloat {
        max(cellWidth * CGFloat(span) + spacing * CGFloat(span - 1), 0)
    }
}

struct RoomWidgetGridRow: Identifiable, Equatable {
    let items: [RoomWidgetPlacement]
    var id: UUID { items[0].widget.id }
}

struct RoomWidgetPlacement: Identifiable, Equatable {
    var id: UUID { widget.id }
    let widget: RoomWidgetDefinition
    let span: Int
}

#Preview("Room Control · iPhone") {
    ZStack {
        AppBackground()
        ScrollView {
            RoomControlGrid(template: .roomControl, columnCount: 2, layoutClass: .phone)
                .padding()
        }
    }
    .environment(AppState())
    .preferredColorScheme(.dark)
    .frame(width: 390, height: 844)
}

#Preview("Room Control · iPad Landscape") {
    ZStack {
        AppBackground()
        ScrollView {
            RoomControlGrid(template: .roomControl, columnCount: 4, layoutClass: .pad)
                .padding()
        }
    }
    .environment(AppState())
    .preferredColorScheme(.dark)
    .frame(width: 1180, height: 820)
}
