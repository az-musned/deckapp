import SwiftUI

struct RoomControlGrid: View {
    let template: RoomControlTemplate
    let columnCount: Int
    let layoutClass: RoomWidgetLayoutClass

    var body: some View {
        Grid(
            alignment: .topLeading,
            horizontalSpacing: DesignToken.Spacing.medium,
            verticalSpacing: DesignToken.Spacing.medium
        ) {
            ForEach(Self.rows(for: resolvedWidgets, columns: columnCount)) { row in
                GridRow(alignment: .top) {
                    ForEach(row.items) { placement in
                        RoomControlWidgetView(definition: placement.widget, compact: columnCount == 2)
                            .frame(maxWidth: .infinity, minHeight: placement.widget.size.minimumHeight, alignment: .topLeading)
                            .gridCellColumns(placement.span)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
