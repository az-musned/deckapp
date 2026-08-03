import Foundation

nonisolated enum DeviceCapabilityKind: String, Codable, CaseIterable, Sendable {
    case power
    case brightness
    case color
    case colorTemperature
    case temperature
    case hvacMode
    case fanMode
    case swingMode
    case volume
    case mute
    case mediaPlayback
    case mediaSeek
    case sourceSelection
    case applicationLaunch
    case directionalRemote
    case sensorValue
    case sceneActivation
    case numericRange
    case selection
    case action
}

nonisolated enum DeviceAvailability: String, Codable, Sendable {
    case available
    case unavailable
    case unknown
}

nonisolated struct NumericRangeCapability: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var name: String
    var minimum: Double
    var maximum: Double
    var step: Double
    var unit: String?
    var currentValue: Double?
    var isWritable: Bool

    var isValid: Bool {
        minimum < maximum && step > 0 && step <= (maximum - minimum)
    }

    func clamped(_ value: Double) -> Double {
        min(maximum, max(minimum, value))
    }
}

nonisolated struct SelectionCapability: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var name: String
    var options: [String]
    var selectedOption: String?
    var isWritable: Bool
}

nonisolated struct DeviceCapabilityDescriptor: Identifiable, Codable, Sendable, Equatable {
    let id: String
    var kind: DeviceCapabilityKind
    var name: String
    var availability: DeviceAvailability
    var isWritable: Bool
    var numericRange: NumericRangeCapability?
    var selection: SelectionCapability?

    init(
        id: String,
        kind: DeviceCapabilityKind,
        name: String,
        availability: DeviceAvailability = .available,
        isWritable: Bool = true,
        numericRange: NumericRangeCapability? = nil,
        selection: SelectionCapability? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.availability = availability
        self.isWritable = isWritable
        self.numericRange = numericRange
        self.selection = selection
    }
}

enum ActionTarget: Codable, Sendable, Equatable {
    case companion(reference: String)
    case homeAssistant(entityID: String, service: String)
    case windowsAgent(command: String)
    case mock(identifier: String)
}

enum BooleanTarget: Codable, Sendable, Equatable {
    case capability(widgetID: UUID, capabilityID: String)
}

enum NumericTarget: Codable, Sendable, Equatable {
    case capability(widgetID: UUID, capabilityID: String)
}

enum SelectionTarget: Codable, Sendable, Equatable {
    case capability(widgetID: UUID, capabilityID: String)
}

enum ControlIntent: Codable, Sendable, Equatable {
    case executeAction(ActionTarget)
    case setBoolean(BooleanTarget, Bool)
    case setNumericValue(NumericTarget, Double)
    case selectOption(SelectionTarget, String)
}
