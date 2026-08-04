import Foundation

@main
struct GoveeFoundationValidation {
    static func main() throws {
        let sample = Data(#"""
        {
          "sku": "H605C",
          "device": "64:09:C5:32:37:36:2D:13",
          "capabilities": [
            {
              "type": "devices.capabilities.on_off",
              "instance": "powerSwitch",
              "parameters": {
                "dataType": "ENUM",
                "options": [
                  { "name": "on", "value": 1 },
                  { "name": "off", "value": 0 }
                ]
              }
            },
            {
              "type": "devices.capabilities.range",
              "instance": "brightness",
              "parameters": {
                "dataType": "INTEGER",
                "range": { "min": 1, "max": 100, "precision": 1 },
                "unit": "unit.percent"
              }
            },
            {
              "type": "devices.capabilities.segment_color_setting",
              "instance": "segmentedColorRgb",
              "parameters": { "dataType": "STRUCT" }
            }
          ]
        }
        """#.utf8)

        let device = try JSONDecoder().decode(GoveeDevice.self, from: sample)
        precondition(device.deviceName == "H605C")
        precondition(device.type == nil)
        precondition(device.actionableCapabilities.map(\.instance) == ["powerSwitch", "brightness"])

        let action = GoveeDeviceAction(
            sku: device.sku,
            device: device.device,
            deviceName: "Desk Light",
            capabilityType: "devices.capabilities.on_off",
            capabilityInstance: "powerSwitch",
            value: .number(1)
        )
        let request = GoveeControlRequest(
            action: action,
            requestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let encoded = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        let payload = object?["payload"] as? [String: Any]
        let capability = payload?["capability"] as? [String: Any]
        precondition(object?["requestId"] as? String == "11111111-2222-3333-4444-555555555555")
        precondition(payload?["sku"] as? String == "H605C")
        precondition(capability?["instance"] as? String == "powerSwitch")
        precondition(capability?["value"] as? Int == 1)

        print("Govee discovery and control payload validation passed")
    }
}
