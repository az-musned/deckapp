import Foundation
import CryptoSwift
import CocoaMQTT

nonisolated struct GreeClimateStateUpdate: Sendable {
    let mac: String
    let state: GreeClimateState
}

protocol GreeClimateServing: Sendable {
    func login(email: String, password: String) async throws
    func discoverDevices() async throws -> [GreeDevice]
    func connectSession(device: GreeDevice) async throws -> AsyncStream<GreeClimateStateUpdate>
    func disconnectSession() async
    func requestStatus(for device: GreeDevice) async throws
    func send(_ command: GreeClimateCommand, to device: GreeDevice) async throws
}

/// Direct client for Gree's consumer cloud API and MQTT broker, bypassing Home
/// Assistant entirely. See docs/architecture.md for why: the AC's local LAN
/// protocol (UDP/7000) was proven dead against this unit's firmware by live
/// diagnostic testing, while the cloud path (login, state read, and writes)
/// was proven to work end-to-end against the real account and device.
actor GreeCloudClimateClient: GreeClimateServing {
    private struct APIEnvelope: Encodable {
        let appId: String
        let r: Int
        let t: String
        let vc: String
    }

    private struct LoginEnvelope: Encodable {
        let api: APIEnvelope
        let datVc: String
        let psw: String
        let t: String
        let user: String
    }

    private struct HomesEnvelope: Encodable {
        let api: APIEnvelope
        let datVc: String
        let t: String
        let token: String
        let uid: String
    }

    private struct DevsEnvelope: Encodable {
        let api: APIEnvelope
        let datVc: String
        let homeId: String
        let t: String
        let token: String
        let uid: String
    }

    private nonisolated static let appId = "4920681951525131286"
    private nonisolated static let appHash = "0fa513124aa97781d1f3f40d61ca1a89"
    private nonisolated static let envelopeKeyBytes = Array("#G$&^jgfujy6ujxt".utf8)

    /// Regional login hosts, tried in order until one accepts the credentials.
    private nonisolated static let regionHosts = [
        "https://nagrih.gree.com",
        "https://eugrih.gree.com",
        "https://hkgrih.gree.com",
        "https://ingrih.gree.com",
        "https://lagrih.gree.com",
        "https://megrih.gree.com",
        "https://rugrih.gree.com",
        "https://sagrih.gree.com",
        "https://augrih.gree.com",
        "https://grih.gree.com"
    ]

    private nonisolated static let mqttHostByRegionHost: [String: String] = [
        "https://nagrih.gree.com": "mqtt-us.gree.com",
        "https://eugrih.gree.com": "mqtt-eu.gree.com",
        "https://hkgrih.gree.com": "mqtt-as.gree.com",
        "https://ingrih.gree.com": "mqtt-in.gree.com",
        "https://lagrih.gree.com": "mqtt-la.gree.com",
        "https://megrih.gree.com": "mqtt-me.gree.com",
        "https://rugrih.gree.com": "mqtt-ru.gree.com",
        "https://sagrih.gree.com": "mqtt-sa.gree.com",
        "https://augrih.gree.com": "mqtt-au.gree.com",
        "https://grih.gree.com": "mqtt-cn.gree.com"
    ]

    private nonisolated static let statusColumns = [
        "Pow", "Mod", "Dwet", "DwatSen", "Dfltr", "DwatFul", "Dmod", "SetTem", "TemSen",
        "TemUn", "TemRec", "WdSpd", "Air", "Blo", "Health", "SwhSlp", "SlpMod", "Lig",
        "SwingLfRig", "SwUpDn", "Quiet", "Tur", "StHt", "SvSt", "HeatCoolType"
    ]

    private let session: URLSession
    private var regionHost: String?
    private var uid: String?
    private var token: String?
    private var lastKnownStates: [String: GreeClimateState] = [:]

    private var mqtt: CocoaMQTT?
    private var mqttBridge: MQTTBridge?
    private var stateContinuation: AsyncStream<GreeClimateStateUpdate>.Continuation?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectedDevice: GreeDevice?

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    // MARK: - Login

    func login(email: String, password: String) async throws {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty, !normalizedPassword.isEmpty else {
            throw GreeClimateError.missingCredentials
        }

        var attemptMessages: [String] = []
        for host in Self.regionHosts {
            do {
                let result = try await attemptLogin(host: host, email: normalizedEmail, password: normalizedPassword)
                regionHost = host
                uid = result.uid
                token = result.token
                return
            } catch {
                attemptMessages.append("\(host): \(error.localizedDescription)")
            }
        }
        throw GreeClimateError.loginFailed(attemptMessages.joined(separator: " | "))
    }

    private func attemptLogin(host: String, email: String, password: String) async throws -> (uid: String, token: String) {
        let t = Self.timestamp()
        let r = Int(Date().timeIntervalSince1970)
        let pwMd5 = password.md5()
        let h = (pwMd5 + password).md5()
        let psw = (h + t).md5()
        let vc = "\(Self.appId)_\(Self.appHash)_\(t)_\(r)".md5()
        let datVc = "\(Self.appHash)_\(email)_\(psw)_\(t)".md5()

        let body = LoginEnvelope(
            api: APIEnvelope(appId: Self.appId, r: r, t: t, vc: vc),
            datVc: datVc,
            psw: psw,
            t: t,
            user: email
        )
        let decoded = try await post(host: host, path: "/App/UserLoginV2", envelope: body, keyBytes: Self.envelopeKeyBytes)
        try Self.validateResult(decoded)
        let payload = (decoded["data"] as? [String: Any]) ?? decoded
        guard let uid = Self.stringValue(payload["uid"]), let token = Self.stringValue(payload["token"]) else {
            throw GreeClimateError.invalidResponse
        }
        return (uid, token)
    }

    // MARK: - Device discovery

    func discoverDevices() async throws -> [GreeDevice] {
        guard let regionHost, let uid, let token else { throw GreeClimateError.missingCredentials }

        let homesT = Self.timestamp()
        let homesBody = HomesEnvelope(
            api: Self.makeAPIEnvelope(t: homesT),
            datVc: Self.makeDatVc(props: [token, uid]),
            t: homesT,
            token: token,
            uid: uid
        )
        let homesResponse = try await post(host: regionHost, path: "/App/GetHomes", envelope: homesBody, keyBytes: Self.envelopeKeyBytes)
        try Self.validateResult(homesResponse)
        let homesPayload = (homesResponse["data"] as? [String: Any]) ?? homesResponse
        let homes = (homesPayload["home"] as? [[String: Any]]) ?? []

        var allDevices: [String: GreeDevice] = [:]
        for home in homes {
            guard let homeId = Self.stringValue(home["id"]) else { continue }
            let devsT = Self.timestamp()
            let devsBody = DevsEnvelope(
                api: Self.makeAPIEnvelope(t: devsT),
                datVc: Self.makeDatVc(props: [token, uid, homeId]),
                homeId: homeId,
                t: devsT,
                token: token,
                uid: uid
            )
            let devsResponse = try await post(host: regionHost, path: "/App/GetDevsInRoomsOfHomeV2", envelope: devsBody, keyBytes: Self.envelopeKeyBytes)
            try Self.validateResult(devsResponse)
            let devsPayload = (devsResponse["data"] as? [String: Any]) ?? devsResponse
            let rooms = (devsPayload["rooms"] as? [[String: Any]]) ?? []
            for room in rooms {
                let devs = (room["devs"] as? [[String: Any]]) ?? []
                for dev in devs {
                    guard let mac = Self.stringValue(dev["mac"]), let key = Self.stringValue(dev["key"]) else { continue }
                    let name = Self.stringValue(dev["name"]) ?? mac
                    allDevices[mac] = GreeDevice(mac: mac, name: name, key: key)
                }
            }
        }

        // Drop synthetic child entries (parent mac + "00" suffix); keep the parent.
        let syntheticChildren = allDevices.keys.filter { mac in
            mac.hasSuffix("00") && allDevices[String(mac.dropLast(2))] != nil
        }
        for mac in syntheticChildren { allDevices.removeValue(forKey: mac) }

        guard !allDevices.isEmpty else { throw GreeClimateError.noDevicesFound }
        return Array(allDevices.values).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - MQTT session

    func connectSession(device: GreeDevice) async throws -> AsyncStream<GreeClimateStateUpdate> {
        guard let regionHost, let uid, let token else { throw GreeClimateError.missingCredentials }
        guard let mqttHost = Self.mqttHostByRegionHost[regionHost] else { throw GreeClimateError.invalidResponse }

        await disconnectSession()
        connectedDevice = device

        let bridge = MQTTBridge()
        let client = CocoaMQTT(clientID: "app_" + Self.randomHex(10), host: mqttHost, port: 1984)
        client.enableSSL = true
        client.username = uid
        client.password = token
        client.cleanSession = true
        client.keepAlive = 60
        client.delegate = bridge
        bridge.owner = self
        mqttBridge = bridge
        mqtt = client

        guard client.connect() else { throw GreeClimateError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
        }

        let macTopic = device.mac.lowercased()
        client.subscribe([
            ("response/\(macTopic)/#", .qos1),
            ("status/\(macTopic)/#", .qos1),
            ("connect/\(macTopic)", .qos1)
        ])

        let (stream, continuation) = AsyncStream<GreeClimateStateUpdate>.makeStream()
        stateContinuation = continuation
        return stream
    }

    func disconnectSession() async {
        stateContinuation?.finish()
        stateContinuation = nil
        connectContinuation = nil
        connectedDevice = nil
        mqtt?.disconnect()
        mqtt = nil
        mqttBridge = nil
    }

    func requestStatus(for device: GreeDevice) async throws {
        try await publishPack(device: device, inner: ["t": "status", "cols": Self.statusColumns])
    }

    func send(_ command: GreeClimateCommand, to device: GreeDevice) async throws {
        let (opt, values) = Self.optionsAndValues(for: command)
        guard !opt.isEmpty else { return }
        try await publishPack(device: device, inner: ["t": "cmd", "opt": opt, "p": values])
    }

    private func publishPack(device: GreeDevice, inner: [String: Any]) async throws {
        guard let mqtt, mqtt.connState == .connected else { throw GreeClimateError.notConnected }
        guard let uid else { throw GreeClimateError.notConnected }

        let innerData = try JSONSerialization.data(withJSONObject: inner)
        let aes = try AES(key: Array(device.key.utf8), blockMode: ECB(), padding: .pkcs7)
        let encrypted = try aes.encrypt(Array(innerData))
        let packBase64 = Data(encrypted).base64EncodedString()

        let outer: [String: Any] = [
            "cid": Self.randomDigits(10),
            "i": 0,
            "pack": packBase64,
            "t": "pack",
            "tcid": device.mac,
            "uid": Int(uid) ?? uid
        ]
        let outerData = try JSONSerialization.data(withJSONObject: outer)
        guard let text = String(data: outerData, encoding: .utf8) else { throw GreeClimateError.invalidResponse }
        mqtt.publish("request/\(device.mac)", withString: text, qos: .qos1)
    }

    // MARK: - Inbound MQTT handling (called from MQTTBridge)

    fileprivate func handleConnectAck(success: Bool) {
        let continuation = connectContinuation
        connectContinuation = nil
        if success {
            continuation?.resume()
        } else {
            continuation?.resume(throwing: GreeClimateError.notConnected)
        }
    }

    fileprivate func handleDisconnect() {
        stateContinuation?.finish()
        stateContinuation = nil
        connectContinuation?.resume(throwing: GreeClimateError.notConnected)
        connectContinuation = nil
    }

    fileprivate func handleIncoming(topic: String, payload: Data) {
        guard let device = connectedDevice,
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let packBase64 = object["pack"] as? String,
              let cipherData = Data(base64Encoded: packBase64) else { return }

        guard let aes = try? AES(key: Array(device.key.utf8), blockMode: ECB(), padding: .noPadding),
              let decryptedBytes = try? aes.decrypt(Array(cipherData)) else { return }
        guard let inner = Self.parseTruncatedJSON(Data(decryptedBytes)) else { return }
        guard inner["t"] as? String == "dat",
              let cols = inner["cols"] as? [String],
              let values = inner["dat"] as? [Any] else { return }

        var props: [String: Any] = [:]
        for (column, value) in zip(cols, values) { props[column] = value }

        let updated = Self.mapState(props: props, previous: lastKnownStates[device.mac])
        lastKnownStates[device.mac] = updated
        stateContinuation?.yield(GreeClimateStateUpdate(mac: device.mac, state: updated))
    }

    // MARK: - Envelope crypto and signing helpers

    private nonisolated static func makeAPIEnvelope(t: String) -> APIEnvelope {
        let r = Int(Date().timeIntervalSince1970)
        let vc = "\(appId)_\(appHash)_\(t)_\(r)".md5()
        return APIEnvelope(appId: appId, r: r, t: t, vc: vc)
    }

    private nonisolated static func makeDatVc(props: [String]) -> String {
        ([Self.appHash] + props).joined(separator: "_").md5()
    }

    private func post<T: Encodable>(host: String, path: String, envelope: T, keyBytes: [UInt8]) async throws -> [String: Any] {
        let data = try JSONEncoder().encode(envelope)
        let aes = try AES(key: keyBytes, blockMode: ECB(), padding: .pkcs7)
        let encrypted = try aes.encrypt(Array(data))
        let base64 = Data(encrypted).base64EncodedString()

        var request = URLRequest(url: URL(string: host + path)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("5ac2bdf935bcca70", forHTTPHeaderField: "Gaen1")
        request.setValue("utf-8", forHTTPHeaderField: "Charset")
        request.httpBody = Data(base64.utf8)

        let (responseData, urlResponse) = try await session.data(for: request)
        guard let http = urlResponse as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw GreeClimateError.invalidResponse
        }
        guard let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let enRes = object["enRes"] as? String,
              let cipherData = Data(base64Encoded: enRes) else {
            throw GreeClimateError.invalidResponse
        }
        let decryptAES = try AES(key: keyBytes, blockMode: ECB(), padding: .noPadding)
        let decryptedBytes = try decryptAES.decrypt(Array(cipherData))
        guard let decoded = Self.parseTruncatedJSON(Data(decryptedBytes)) else {
            throw GreeClimateError.invalidResponse
        }
        return decoded
    }

    // MARK: - Static helpers

    private nonisolated static func validateResult(_ decoded: [String: Any]) throws {
        if let r = decoded["r"] as? Int, r != 200 {
            throw GreeClimateError.loginFailed(decoded["msg"] as? String ?? "Gree rejected the request.")
        }
    }

    private nonisolated static func parseTruncatedJSON(_ data: Data) -> [String: Any]? {
        var trimmed = data
        if let lastBrace = trimmed.lastIndex(of: UInt8(ascii: "}")) {
            trimmed = trimmed[trimmed.startIndex...lastBrace]
        }
        return try? JSONSerialization.jsonObject(with: trimmed) as? [String: Any]
    }

    private nonisolated static func stringValue(_ any: Any?) -> String? {
        switch any {
        case let value as String: value
        case let value as Int: String(value)
        case let value as NSNumber: value.stringValue
        default: nil
        }
    }

    private nonisolated static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let value as Int: value
        case let value as NSNumber: value.intValue
        case let value as String: Int(value)
        default: nil
        }
    }

    private nonisolated static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Force Gregorian explicitly: a device with Region set to Saudi Arabia
        // (or others using Umm al-Qura) can otherwise format this in the
        // device's Hijri calendar even under a POSIX locale, silently
        // producing a wrong year/date and breaking every signed request.
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter.string(from: .now)
    }

    private nonisolated static func randomHex(_ length: Int) -> String {
        String((0..<length).map { _ in "0123456789abcdef".randomElement()! })
    }

    private nonisolated static func randomDigits(_ length: Int) -> String {
        String((0..<length).map { _ in "0123456789".randomElement()! })
    }

    private nonisolated static func optionsAndValues(for command: GreeClimateCommand) -> ([String], [Any]) {
        switch command {
        case .setPower(let isOn):
            return (["Pow"], [isOn ? 1 : 0])
        case .setTargetTemperature(let temperature):
            // The AC's half-degree steps ride on a separate "TemRec" bit
            // alongside the whole-degree SetTem value, not on SetTem itself.
            let snapped = (temperature * 2).rounded() / 2
            let whole = Int(snapped.rounded(.down))
            let isHalf = snapped - snapped.rounded(.down) >= 0.25
            return (["SetTem", "TemRec"], [whole, isHalf ? 1 : 0])
        case .setMode(let mode):
            return (["Mod"], [mode.rawValue])
        case .setFanMode(let fan):
            return (["WdSpd"], [fan.rawValue])
        case .setSwing(let vertical, let horizontal):
            var opt: [String] = []
            var values: [Any] = []
            if let vertical {
                opt.append("SwUpDn")
                values.append(vertical.rawValue)
            }
            if let horizontal {
                opt.append("SwingLfRig")
                values.append(horizontal.rawValue)
            }
            return (opt, values)
        }
    }

    /// Maps a decoded `cols`/`dat` property snapshot onto the previous known
    /// state, preserving fields absent from a partial push update.
    ///
    /// `TemSen` is applied with the common Gree "+40" room-temperature offset
    /// convention. This was not independently confirmed against a live current-
    /// temperature read during protocol validation (only `SetTem`/`WdSpd` writes
    /// were confirmed) -- verify against a real device reading and adjust here
    /// if the displayed current temperature is off by 40 degrees.
    private nonisolated static func mapState(props: [String: Any], previous: GreeClimateState?) -> GreeClimateState {
        var state = previous ?? .unknown
        if let pow = intValue(props["Pow"]) { state.power = pow == 1 }
        // TemRec is the AC's half-degree bit for the target temperature; it
        // can arrive in the same push as SetTem or separately, so only
        // recompute the half-degree part from whichever of the two is present.
        if let setTem = intValue(props["SetTem"]) {
            let half = intValue(props["TemRec"]) ?? (state.targetTemperature.truncatingRemainder(dividingBy: 1) >= 0.25 ? 1 : 0)
            state.targetTemperature = Double(setTem) + (half == 1 ? 0.5 : 0)
        } else if let temRec = intValue(props["TemRec"]) {
            let whole = state.targetTemperature.rounded(.down)
            state.targetTemperature = whole + (temRec == 1 ? 0.5 : 0)
        }
        if let mod = intValue(props["Mod"]), let mode = GreeHVACMode(rawValue: mod) { state.hvacMode = mode }
        if let wdSpd = intValue(props["WdSpd"]), let fan = GreeFanSpeed(rawValue: wdSpd) { state.fanMode = fan }
        if let swUpDn = intValue(props["SwUpDn"]), let swing = GreeSwingPosition(rawValue: swUpDn) { state.verticalSwing = swing }
        if let swingLfRig = intValue(props["SwingLfRig"]), let swing = GreeSwingPosition(rawValue: swingLfRig) { state.horizontalSwing = swing }
        if let temSen = intValue(props["TemSen"]) { state.currentTemperature = Double(temSen) - 40 }
        state.availability = .reachable
        state.confidence = .confirmed
        state.lastUpdated = .now
        return state
    }
}

/// Bridges CocoaMQTT's synchronous, background-queue delegate callbacks into
/// the GreeCloudClimateClient actor.
private nonisolated final class MQTTBridge: NSObject, CocoaMQTTDelegate, @unchecked Sendable {
    weak var owner: GreeCloudClimateClient?

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        let success = ack == .accept
        Task { [owner] in await owner?.handleConnectAck(success: success) }
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        let topic = message.topic
        let payload = Data(message.payload)
        Task { [owner] in await owner?.handleIncoming(topic: topic, payload: payload) }
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        Task { [owner] in await owner?.handleDisconnect() }
    }

    /// Gree's real broker requires accepting its certificate without chain
    /// validation; this was confirmed necessary during live protocol testing.
    func mqtt(_ mqtt: CocoaMQTT, didReceive trust: SecTrust, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}
