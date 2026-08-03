import Foundation

nonisolated enum HomeAssistantCapabilityDiscovery {
    static func capabilities(for entity: HAEntityState) -> [DeviceCapabilityDescriptor] {
        let availability: DeviceAvailability = entity.isAvailable ? .available : .unavailable
        switch entity.domain {
        case "light":
            var result = [DeviceCapabilityDescriptor(id: "power", kind: .power, name: "Power", availability: availability)]
            if entity.attributes["brightness"] != nil || !entity.stringArrayAttribute("supported_color_modes").isEmpty {
                result.append(DeviceCapabilityDescriptor(
                    id: "brightness", kind: .brightness, name: "Brightness", availability: availability,
                    numericRange: NumericRangeCapability(id: "brightness", name: "Brightness", minimum: 0, maximum: 100, step: 1, unit: "%", currentValue: entity.numberAttribute("brightness").map { $0 / 255 * 100 }, isWritable: true)
                ))
            }
            if entity.attributes["color_temp_kelvin"] != nil || entity.attributes["min_color_temp_kelvin"] != nil {
                result.append(DeviceCapabilityDescriptor(
                    id: "color_temperature", kind: .colorTemperature, name: "Color Temperature", availability: availability,
                    numericRange: NumericRangeCapability(
                        id: "color_temperature", name: "Color Temperature",
                        minimum: entity.numberAttribute("min_color_temp_kelvin") ?? 2000,
                        maximum: entity.numberAttribute("max_color_temp_kelvin") ?? 6500,
                        step: 50, unit: "K", currentValue: entity.numberAttribute("color_temp_kelvin"), isWritable: true
                    )
                ))
            }
            return result
        case "climate":
            var result: [DeviceCapabilityDescriptor] = []
            if entity.attributes["temperature"] != nil {
                result.append(DeviceCapabilityDescriptor(
                    id: "temperature", kind: .temperature, name: "Target Temperature", availability: availability,
                    numericRange: NumericRangeCapability(
                        id: "temperature", name: "Target Temperature",
                        minimum: entity.numberAttribute("min_temp") ?? 16,
                        maximum: entity.numberAttribute("max_temp") ?? 30,
                        step: entity.numberAttribute("target_temp_step") ?? 0.5,
                        unit: entity.stringAttribute("temperature_unit"),
                        currentValue: entity.numberAttribute("temperature"), isWritable: true
                    )
                ))
            }
            result += selection("hvac_mode", .hvacMode, "HVAC Mode", "hvac_modes", entity, availability)
            result += selection("fan_mode", .fanMode, "Fan Mode", "fan_modes", entity, availability)
            result += selection("swing_mode", .swingMode, "Swing Mode", "swing_modes", entity, availability)
            return result
        case "media_player":
            let features = Int(entity.numberAttribute("supported_features") ?? 0)
            var result: [DeviceCapabilityDescriptor] = []
            if supports(features, 128) || supports(features, 256) {
                result.append(DeviceCapabilityDescriptor(id: "power", kind: .power, name: "Power", availability: availability))
            }
            if supports(features, 4), entity.attributes["volume_level"] != nil {
                result.append(DeviceCapabilityDescriptor(
                    id: "volume", kind: .volume, name: "Volume", availability: availability,
                    numericRange: NumericRangeCapability(id: "volume", name: "Volume", minimum: 0, maximum: 100, step: 1, unit: "%", currentValue: entity.numberAttribute("volume_level").map { $0 * 100 }, isWritable: true)
                ))
            }
            if supports(features, 8), entity.attributes["is_volume_muted"] != nil {
                result.append(DeviceCapabilityDescriptor(id: "mute", kind: .mute, name: "Mute", availability: availability))
            }
            if supports(features, 1) || supports(features, 16384) {
                result.append(DeviceCapabilityDescriptor(id: "media_playback", kind: .mediaPlayback, name: "Playback", availability: availability))
            }
            let sources = entity.stringArrayAttribute("source_list")
            if supports(features, 2048), !sources.isEmpty {
                result.append(DeviceCapabilityDescriptor(id: "source", kind: .sourceSelection, name: "Source", availability: availability, selection: SelectionCapability(id: "source", name: "Source", options: sources, selectedOption: entity.stringAttribute("source"), isWritable: true)))
            }
            return result
        case "remote":
            return [DeviceCapabilityDescriptor(id: "directional_remote", kind: .directionalRemote, name: "Directional Remote", availability: availability)]
        case "switch":
            return [DeviceCapabilityDescriptor(id: "power", kind: .power, name: "Power", availability: availability)]
        case "binary_sensor":
            return [DeviceCapabilityDescriptor(id: "state", kind: .sensorValue, name: "Binary State", availability: availability, isWritable: false)]
        case "script":
            return [DeviceCapabilityDescriptor(id: "run", kind: .action, name: "Run Script", availability: availability)]
        case "scene":
            return [DeviceCapabilityDescriptor(id: "activate", kind: .sceneActivation, name: "Activate Scene", availability: availability)]
        default:
            return []
        }
    }

    private static func supports(_ features: Int, _ flag: Int) -> Bool {
        features & flag == flag
    }

    private static func selection(
        _ id: String, _ kind: DeviceCapabilityKind, _ name: String, _ optionsKey: String,
        _ entity: HAEntityState, _ availability: DeviceAvailability
    ) -> [DeviceCapabilityDescriptor] {
        let options = entity.stringArrayAttribute(optionsKey)
        guard !options.isEmpty else { return [] }
        return [DeviceCapabilityDescriptor(
            id: id, kind: kind, name: name, availability: availability,
            selection: SelectionCapability(id: id, name: name, options: options, selectedOption: entity.stringAttribute(id) ?? entity.state, isWritable: true)
        )]
    }
}
