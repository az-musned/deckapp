import Foundation

@main
struct RoomControlValidation {
    static func main() throws {
        let validRange = NumericRangeCapability(
            id: "brightness",
            name: "Brightness",
            minimum: 0,
            maximum: 100,
            step: 1,
            unit: "%",
            currentValue: 50,
            isWritable: true
        )
        precondition(validRange.isValid)
        precondition(validRange.clamped(-10) == 0)
        precondition(validRange.clamped(130) == 100)

        let invalidRange = NumericRangeCapability(
            id: "invalid",
            name: "Invalid",
            minimum: 100,
            maximum: 0,
            step: 0,
            unit: nil,
            currentValue: nil,
            isWritable: false
        )
        precondition(!invalidRange.isValid)

        let template = RoomControlTemplate.roomControl
        precondition(template.widgets.count == 7)
        precondition(template.widgets.map(\.kind) == [.light, .climate, .television, .pcPower, .remoteInputLauncher, .audioMixer, .companionActions])
        precondition(template.widgets.last?.backend.backend == .companion)

        let climate = template.widgets.first { $0.kind == .climate }!
        precondition(climate.capabilities.contains { $0.kind == .temperature })
        precondition(climate.capabilities.contains { $0.kind == .fanMode })
        precondition(!climate.capabilities.contains { $0.kind == .volume })

        let pcPower = template.widgets.first { $0.kind == .pcPower }!
        precondition(pcPower.capabilities.contains { $0.id == "start_pc" })
        precondition(!pcPower.capabilities.contains { $0.id == "turn_off_plug" })

        precondition(RoomWidgetSize.medium.columnSpan(in: 4) == 2)
        precondition(RoomWidgetSize.wide.columnSpan(in: 4) == 4)
        precondition(RoomWidgetSize.wide.columnSpan(in: 2) == 2)
        precondition(RoomWidgetSize.banner.columnSpan(in: 4) == 4)
        precondition(RoomWidgetSize.small.presentationDensity == .compact)
        precondition(RoomWidgetSize.medium.presentationDensity == .standard)
        precondition(RoomWidgetSize.large.presentationDensity == .expanded)

        var overridden = template.widgets[0]
        overridden.phoneSize = .wide
        overridden.padSize = .small
        precondition(overridden.resolvedSize(for: .phone) == .wide)
        precondition(overridden.resolvedSize(for: .pad) == .small)
        let duplicate = overridden.duplicated()
        precondition(duplicate.id != overridden.id)
        precondition(duplicate.phoneSize == .wide && duplicate.padSize == .small)

        var goveeWidget = duplicate
        goveeWidget.backend = WidgetBackendReference(backend: .govee, identifier: "H605C|device-id")
        let goveeData = try JSONEncoder().encode(goveeWidget)
        let restoredGoveeWidget = try JSONDecoder().decode(RoomWidgetDefinition.self, from: goveeData)
        precondition(restoredGoveeWidget.backend.backend == .govee)
        precondition(restoredGoveeWidget.backend.identifier == "H605C|device-id")

        let encoded = try JSONEncoder().encode(template)
        let decoded = try JSONDecoder().decode(RoomControlTemplate.self, from: encoded)
        precondition(decoded == template)

        print("Room Control capability and template validation passed")
    }
}
