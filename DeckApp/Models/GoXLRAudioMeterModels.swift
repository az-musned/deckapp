import Foundation

nonisolated struct AudioMetersMessage: Codable, Sendable, Equatable {
    let type: String
    let sequence: UInt64
    let timestamp: Int64
    let channels: [AudioMeterChannelPayload]
}

nonisolated struct AudioMeterChannelPayload: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let endpointId: String?
    let available: Bool
    let linearPeak: Double
    let decibels: Double
    let displayLevel: Double
    let peakHold: Double
    let clipping: Bool

    var clamped: Self {
        Self(
            id: id,
            endpointId: endpointId,
            available: available,
            linearPeak: linearPeak.clampedToUnitInterval,
            decibels: decibels.isFinite ? decibels : -120,
            displayLevel: displayLevel.clampedToUnitInterval,
            peakHold: peakHold.clampedToUnitInterval,
            clipping: clipping
        )
    }
}

nonisolated struct GoXLRChannelState: Identifiable, Equatable, Sendable {
    let id: String
    var displayName: String
    var volume: Double
    var isMuted: Bool
    var isAvailable: Bool
    var endpointID: String?
    var endpointName: String?
    var linearPeak: Double
    var decibels: Double
    var displayLevel: Double
    var peakHold: Double
    var isClipping: Bool
    var lastMeterUpdate: Date?

    init(control: WindowsGoXLRChannelState) {
        id = control.id
        displayName = control.name
        volume = control.level.clampedToUnitInterval
        isMuted = control.isMuted
        isAvailable = true
        linearPeak = 0
        decibels = -120
        displayLevel = 0
        peakHold = 0
        isClipping = false
    }
}

nonisolated enum AudioMeterConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case failed(String)

    var title: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting"
        case .connected: "Live"
        case .reconnecting: "Reconnecting"
        case .failed: "Unavailable"
        }
    }
}

nonisolated struct WindowsAudioEndpoint: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let dataFlow: String
    let available: Bool
    let isDefault: Bool?
    let suggestedChannelIds: [String]?

    var kindTitle: String { dataFlow.lowercased() == "capture" ? "Input" : "Output" }

    private enum CodingKeys: String, CodingKey {
        case id, endpointId, name, displayName, dataFlow, flow, available, isDefault, suggestedChannelIds, suggestedChannels
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? values.decode(String.self, forKey: .endpointId)
        name = try values.decodeIfPresent(String.self, forKey: .name)
            ?? values.decode(String.self, forKey: .displayName)
        dataFlow = try values.decodeIfPresent(String.self, forKey: .dataFlow)
            ?? values.decodeIfPresent(String.self, forKey: .flow) ?? "render"
        available = try values.decodeIfPresent(Bool.self, forKey: .available) ?? true
        isDefault = try values.decodeIfPresent(Bool.self, forKey: .isDefault)
        suggestedChannelIds = try values.decodeIfPresent([String].self, forKey: .suggestedChannelIds)
            ?? values.decodeIfPresent([String].self, forKey: .suggestedChannels)
    }


    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(dataFlow, forKey: .dataFlow)
        try values.encode(available, forKey: .available)
        try values.encodeIfPresent(isDefault, forKey: .isDefault)
        try values.encodeIfPresent(suggestedChannelIds, forKey: .suggestedChannelIds)
    }
}

nonisolated struct GoXLRAudioChannelMapping: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let endpointId: String?
    let endpointName: String?
    let endpointAvailable: Bool
    let suggestedEndpointId: String?

    private enum CodingKeys: String, CodingKey {
        case id, channelId, name, displayName, endpointId, endpointName, endpointAvailable, suggestedEndpointId
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(String.self, forKey: .id)
            ?? values.decode(String.self, forKey: .channelId)
        name = try values.decodeIfPresent(String.self, forKey: .name)
            ?? values.decodeIfPresent(String.self, forKey: .displayName) ?? id
        endpointId = try values.decodeIfPresent(String.self, forKey: .endpointId)
        endpointName = try values.decodeIfPresent(String.self, forKey: .endpointName)
        endpointAvailable = try values.decodeIfPresent(Bool.self, forKey: .endpointAvailable) ?? (endpointId != nil)
        suggestedEndpointId = try values.decodeIfPresent(String.self, forKey: .suggestedEndpointId)
    }


    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(endpointId, forKey: .endpointId)
        try values.encodeIfPresent(endpointName, forKey: .endpointName)
        try values.encode(endpointAvailable, forKey: .endpointAvailable)
        try values.encodeIfPresent(suggestedEndpointId, forKey: .suggestedEndpointId)
    }
}

nonisolated struct AudioMeterSequenceTracker: Sendable {
    private(set) var latest: UInt64?

    mutating func accepts(_ sequence: UInt64) -> Bool {
        guard latest.map({ sequence > $0 }) ?? true else { return false }
        latest = sequence
        return true
    }

    mutating func reset() { latest = nil }
}

nonisolated struct AudioChannelMappingRequest: Codable, Sendable, Equatable {
    let endpointId: String?
}

nonisolated enum GoXLRChannelStateReducer {
    static func apply(_ message: AudioMetersMessage, to channels: inout [GoXLRChannelState], now: Date) {
        var indices = Dictionary(uniqueKeysWithValues: channels.indices.map { (channels[$0].id, $0) })
        for rawPayload in message.channels {
            let payload = rawPayload.clamped
            if indices[payload.id] == nil {
                let fallback = WindowsGoXLRChannelState(id: payload.id, name: payload.id, level: 0, isMuted: false)
                channels.append(GoXLRChannelState(control: fallback))
                indices[payload.id] = channels.index(before: channels.endIndex)
            }
            guard let index = indices[payload.id] else { continue }
            channels[index].endpointID = payload.endpointId
            channels[index].isAvailable = payload.available
            channels[index].linearPeak = payload.linearPeak
            channels[index].decibels = payload.decibels
            channels[index].displayLevel = payload.displayLevel
            channels[index].peakHold = payload.peakHold
            channels[index].isClipping = payload.clipping
            channels[index].lastMeterUpdate = now
        }
    }

    static func decay(_ channels: inout [GoXLRChannelState], elapsed: TimeInterval) {
        let factor = elapsed >= 4 ? 0 : 0.72
        for index in channels.indices {
            channels[index].displayLevel *= factor
            channels[index].linearPeak *= factor
            channels[index].peakHold = max(channels[index].displayLevel, channels[index].peakHold * factor)
            channels[index].isClipping = false
            if elapsed >= 4 { channels[index].decibels = -120 }
        }
    }
}

nonisolated private extension Double {
    var clampedToUnitInterval: Double { min(max(isFinite ? self : 0, 0), 1) }
}
