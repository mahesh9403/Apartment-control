import Foundation

/// The transport boundary keeps the LG client testable without contacting a real appliance.
public protocol LGThinQTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct LGThinQURLSessionTransport: LGThinQTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: configuration)
        }
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceFailure("LG ThinQ returned a response that was not HTTP")
        }
        return (data, http)
    }
}

/// Native LG ThinQ Connect support for air conditioners.
///
/// This uses LG's documented PAT-based REST API directly. It intentionally starts with
/// polling instead of MQTT: the existing House Control hub already polls linked services,
/// and no cloud-side client certificate is needed for the first usable slice.
@MainActor
public final class LGThinQService: DeviceService {
    public let id = "lgthinq"
    public let title = "LG ThinQ"
    public var onChange: (() -> Void)?

    struct Config: Codable, Equatable {
        var country: String
        var token: String
        var clientID: String
    }

    struct Profile {
        var modes: [String: String] = [:]       // panel name -> LG value
        var fans: [String: String] = [:]        // panel name -> LG value
        var range: (min: Double, max: Double)?
        var temperatureTargets: [String: TemperatureTarget] = [:] // mode/default -> LG property
        var fanKey = "windStrength"
        var swing = false
        var eco = false
        var powerOn = "POWER_ON"
        var powerOff = "POWER_OFF"

        var detail: String {
            let modeText = modes.keys.sorted().joined(separator: ", ")
            return modeText.isEmpty ? "air conditioner" : "air conditioner · \(modeText)"
        }
    }

    struct TemperatureTarget {
        var key: String
        var range: (min: Double, max: Double)?
    }

    private static let apiKey = "v6GFvkweNo7DK7yD3ylIZ9w52aKBU0eJ7wLXkSR3"
    private static let deviceType = "DEVICE_AIR_CONDITIONER"

    private let vault: SecretStore
    private let transport: LGThinQTransport
    private var config: Config?
    private var profiles: [String: Profile] = [:]
    private var deviceCount = 0

    public init(vault: SecretStore, transport: LGThinQTransport = LGThinQURLSessionTransport()) {
        self.vault = vault
        self.transport = transport
        config = vault.read().flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
    }

    public var isConnected: Bool { config != nil }

    public var info: [String: Any] {
        guard let config else { return ["connected": false] }
        return [
            "connected": true,
            "name": "LG ThinQ",
            "country": config.country,
            "region": Self.region(for: config.country) ?? "",
            "devices": deviceCount,
        ]
    }

    /// Checks the PAT against the India endpoint and stores it only in the supplied secret store.
    public func connect(country rawCountry: String = "IN", token rawToken: String) async throws {
        let country = rawCountry.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let region = Self.region(for: country) else {
            throw ServiceFailure("LG ThinQ Connect does not support country code \(country).")
        }
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw ServiceFailure("Paste an LG ThinQ Connect Personal Access Token.")
        }

        let clientID = config?.country == country ? config?.clientID : nil
        let candidate = Config(country: country, token: token, clientID: clientID ?? UUID().uuidString)
        _ = try await request("GET", "/devices", config: candidate, region: region)
        config = candidate
        profiles.removeAll()
        deviceCount = 0
        let encoded = try JSONEncoder().encode(candidate)
        vault.write(encoded)
        guard vault.read() == encoded else {
            config = nil
            throw ServiceFailure("LG ThinQ connected, but House Control could not save the credential securely.")
        }
    }

    public func disconnect() {
        config = nil
        profiles.removeAll()
        deviceCount = 0
        vault.write(nil)
    }

    public func devices() async throws -> [ServiceDevice] {
        let list = try await deviceList()
        var result: [ServiceDevice] = []
        for item in list {
            let details = Self.deviceDetails(item)
            guard Self.isAirConditioner(item), let id = Self.string(item, "deviceId") else { continue }
            let name = Self.string(details, "alias") ?? Self.string(details, "modelName") ?? id
            let profile: Profile
            do {
                profile = try await loadProfile(id: id)
            } catch {
                // Discovery should still show a supported AC when a model profile is temporarily unavailable.
                profile = Profile()
            }
            var device = ServiceDevice(id: id, name: name, kind: .ac)
            device.range = profile.range
            device.detail = profile.detail
            device.online = Self.online(item)
            result.append(device)
        }
        deviceCount = result.count
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func read(_ ids: Set<String>) async throws -> [String: DeviceReading] {
        guard !ids.isEmpty else { return [:] }
        var out: [String: DeviceReading] = [:]
        for id in ids {
            let profile = try await profileFor(id: id)
            let state = try await request("GET", "/devices/\(Self.path(id))/state") as? [String: Any] ?? [:]
            out[id] = Self.reading(from: state, profile: profile)
        }
        return out
    }

    public func send(kind: DeviceKind, id: String, patch: [String: Any], state: [String: Any]) async throws {
        guard kind == .ac else { throw ServiceFailure("LG ThinQ only exposes air conditioners here.") }
        let profile = try await profileFor(id: id)
        guard !patch.isEmpty else { return }

        // Turning an AC off is intentionally a single operation. Sending a stale temperature or
        // mode beside POWER_OFF can make some LG models reject the whole conditional command.
        if let on = patch["on"] as? Bool, !on {
            _ = try await request("POST", "/devices/\(Self.path(id))/control",
                                  body: ["operation": ["airConOperationMode": profile.powerOff]],
                                  control: true)
            return
        }

        var body: [String: Any] = [:]
        if let on = patch["on"] as? Bool, on {
            body["operation"] = ["airConOperationMode": profile.powerOn]
        }
        if let mode = patch["mode"] as? String {
            guard let actual = profile.modes[mode] else {
                throw ServiceFailure("This LG AC does not expose the \(mode) mode through ThinQ Connect.")
            }
            body["airConJobMode"] = ["currentJobMode": actual]
        }
        if let target = patch.double("target") {
            let mode = (patch["mode"] as? String) ?? (state["mode"] as? String) ?? "default"
            let targetControl = profile.temperatureTargets[mode] ?? profile.temperatureTargets["default"]
            if let range = targetControl?.range ?? profile.range, (target < range.min || target > range.max) {
                throw ServiceFailure("Set the temperature between \(Self.pretty(range.min))° and \(Self.pretty(range.max))°.")
            }
            guard let targetControl else {
                throw ServiceFailure("This LG AC does not expose a writable temperature setting through ThinQ Connect.")
            }
            body["temperatureInUnits"] = [targetControl.key: target, "unit": "C"]
        }
        if let fan = patch["fan"] as? String {
            guard let actual = profile.fans[fan] else {
                throw ServiceFailure("This LG AC does not expose the \(fan) fan setting through ThinQ Connect.")
            }
            body["airFlow"] = [profile.fanKey: actual]
        }
        if let swing = patch["swing"] as? String {
            guard profile.swing else { throw ServiceFailure("This LG AC does not expose swing control through ThinQ Connect.") }
            body["windDirection"] = ["rotateUpDown": swing != "off"]
        }
        if let eco = patch["eco"] as? Bool {
            guard profile.eco else { throw ServiceFailure("This LG AC does not expose energy saving through ThinQ Connect.") }
            body["powerSave"] = ["powerSaveEnabled": eco]
        }
        if patch["sleep"] != nil {
            throw ServiceFailure("Sleep timers are not exposed by this first LG ThinQ connector.")
        }
        guard !body.isEmpty else { return }
        _ = try await request("POST", "/devices/\(Self.path(id))/control", body: body, control: true)
    }

    // MARK: - Pure mapping helpers

    static func region(for country: String) -> String? {
        switch country.uppercased() {
        case "IN": return "kic"
        default: return nil
        }
    }

    static func isAirConditioner(_ device: [String: Any]) -> Bool {
        string(deviceDetails(device), "deviceType") == deviceType
    }

    /// LG has returned both flattened and `deviceInfo`-nested catalog entries over time.
    static func deviceDetails(_ device: [String: Any]) -> [String: Any] {
        device["deviceInfo"] as? [String: Any] ?? device
    }

    static func online(_ device: [String: Any]) -> Bool {
        if let connected = device["connected"] as? Bool { return connected }
        if let online = device["online"] as? Bool { return online }
        if let connected = deviceDetails(device)["connected"] as? Bool { return connected }
        if let online = deviceDetails(device)["online"] as? Bool { return online }
        return true
    }

    static func profile(from response: [String: Any]) -> Profile {
        let root = (response["profile"] as? [String: Any]) ?? response
        let properties = root["property"] as? [String: Any] ?? [:]
        var profile = Profile()

        let modeValues = writableEnumValues(in: properties["airConJobMode"] as? [String: Any], key: "currentJobMode")
        for value in modeValues {
            if let panel = panelMode(value) { profile.modes[panel] = value }
        }
        let fanResource = properties["airFlow"] as? [String: Any]
        let detailedFans = writableEnumValues(in: fanResource, key: "windStrengthDetail")
        let fanKey = detailedFans.isEmpty ? "windStrength" : "windStrengthDetail"
        profile.fanKey = fanKey
        let fanValues = detailedFans.isEmpty ? writableEnumValues(in: fanResource, key: fanKey) : detailedFans
        for value in fanValues {
            if let panel = FanNames.panel(value) { profile.fans[panel] = value }
        }
        let powerValues = writableEnumValues(in: properties["operation"] as? [String: Any], key: "airConOperationMode")
        profile.powerOn = powerValues.first(where: { $0.lowercased().contains("on") }) ?? "POWER_ON"
        profile.powerOff = powerValues.first(where: { $0.lowercased().contains("off") }) ?? "POWER_OFF"
        let entries = temperatureEntries(from: properties["temperatureInUnits"])
        for entry in entries where (entry["unit"] as? String ?? "C").uppercased() == "C" {
            for (mode, key) in [("default", "targetTemperature"), ("cool", "coolTargetTemperature"),
                                ("heat", "heatTargetTemperature"), ("auto", "autoTargetTemperature")] {
                if let target = temperatureTarget(from: entry, key: key) {
                    profile.temperatureTargets[mode] = target
                }
            }
        }
        profile.range = profile.temperatureTargets.values.compactMap(\.range).first ?? temperatureRange(from: properties["temperatureInUnits"])

        if let direction = properties["windDirection"] as? [String: Any],
           let rotate = direction["rotateUpDown"] as? [String: Any] {
            profile.swing = isWritable(rotate)
        }
        if let save = properties["powerSave"] as? [String: Any],
           let enabled = save["powerSaveEnabled"] as? [String: Any] {
            profile.eco = isWritable(enabled)
        }
        return profile
    }

    static func reading(from state: [String: Any], profile: Profile) -> DeviceReading {
        let operation = resource(state, "operation")?.string("airConOperationMode") ?? "POWER_ON"
        let on = !operation.lowercased().contains("off")
        var ac: [String: Any] = ["on": on]

        if let rawMode = resource(state, "airConJobMode")?.string("currentJobMode"),
           let mode = panelMode(rawMode) { ac["mode"] = mode }
        if let temperature = temperatureResource(state) {
            let mode = ac["mode"] as? String ?? ""
            let targetKey = profile.temperatureTargets[mode]?.key ?? profile.temperatureTargets["default"]?.key ?? "targetTemperature"
            if let target = temperature.double(targetKey) ?? temperature.double("targetTemperature") {
                ac["target"] = target
            }
            if let current = temperature.double("currentTemperature") { ac["roomTemp"] = current }
        }
        let fanResource = resource(state, "airFlow")
        if let rawFan = fanResource?.string(profile.fanKey) ?? fanResource?.string("windStrength") ?? fanResource?.string("windStrengthDetail"),
           let fan = FanNames.panel(rawFan), profile.fans[fan] != nil { ac["fan"] = fan }
        if let swing = resource(state, "windDirection")?.bool("rotateUpDown") { ac["swing"] = swing ? "swing" : "off" }
        if let eco = resource(state, "powerSave")?.bool("powerSaveEnabled") { ac["eco"] = eco }

        let features: [String: Any] = [
            "modes": ["cool", "heat", "dry", "fan", "auto"].filter { profile.modes[$0] != nil },
            "fans": FanNames.order.filter { profile.fans[$0] != nil },
            "swing": profile.swing,
            "sleep": false,
            "eco": profile.eco,
        ]
        return DeviceReading(ac: ac, features: features)
    }

    static func panelMode(_ raw: String) -> String? {
        let value = raw.lowercased().replacingOccurrences(of: "_", with: " ")
        if value.contains("cool") { return "cool" }
        if value.contains("heat") { return "heat" }
        if value.contains("dry") || value.contains("dehumid") { return "dry" }
        if value.contains("fan") { return "fan" }
        if value.contains("auto") || value.contains("heat cool") { return "auto" }
        return nil
    }

    // MARK: - Profile and transport

    private func deviceList() async throws -> [[String: Any]] {
        let response = try await request("GET", "/devices")
        if let list = response as? [[String: Any]] { return list }
        if let dictionary = response as? [String: Any], let list = dictionary["devices"] as? [[String: Any]] { return list }
        return []
    }

    private func loadProfile(id: String) async throws -> Profile {
        let response = try await request("GET", "/devices/\(Self.path(id))/profile") as? [String: Any] ?? [:]
        let profile = Self.profile(from: response)
        profiles[id] = profile
        return profile
    }

    private func profileFor(id: String) async throws -> Profile {
        if let profile = profiles[id] { return profile }
        return try await loadProfile(id: id)
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                         control: Bool = false, config: Config? = nil, region: String? = nil) async throws -> Any? {
        let active = config ?? self.config
        guard let active else { throw ServiceFailure("Connect LG ThinQ first.") }
        let region = region ?? Self.region(for: active.country)
        guard let region, let url = URL(string: "https://api-\(region).lgthinq.com\(path)") else {
            throw ServiceFailure("LG ThinQ region is not configured.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(active.token)", forHTTPHeaderField: "Authorization")
        request.setValue(active.country, forHTTPHeaderField: "x-country")
        request.setValue(Self.messageID(), forHTTPHeaderField: "x-message-id")
        request.setValue(active.clientID, forHTTPHeaderField: "x-client-id")
        request.setValue(Self.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("OP", forHTTPHeaderField: "x-service-phase")
        if control { request.setValue("true", forHTTPHeaderField: "x-conditional-control") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch {
            throw ServiceFailure("LG ThinQ did not answer: \(error.localizedDescription)")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(response.statusCode) else {
            let error = json?["error"] as? [String: Any]
            let code = error?.string("code") ?? "\(response.statusCode)"
            let message = error?.string("message") ?? "request failed"
            throw ServiceFailure("LG ThinQ error \(code): \(message)")
        }
        if let json, let result = json["response"] { return result }
        return json
    }

    private static func path(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private static func messageID() -> String {
        var uuid = UUID().uuid
        let data = withUnsafeBytes(of: &uuid) { Data($0) }
        return data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func string(_ dictionary: [String: Any], _ key: String) -> String? {
        if let value = dictionary[key] as? String { return value }
        if let value = dictionary[key] as? NSNumber { return value.stringValue }
        return nil
    }

    private static func resource(_ state: [String: Any], _ key: String) -> [String: Any]? {
        if let value = state[key] as? [String: Any] { return value }
        if let values = state[key] as? [[String: Any]] {
            return values.first(where: { $0["unit"] as? String == "C" }) ?? values.first
        }
        return nil
    }

    private static func temperatureResource(_ state: [String: Any]) -> [String: Any]? {
        resource(state, "temperatureInUnits") ?? resource(state, "temperature")
    }

    private static func writableEnumValues(in resource: [String: Any]?, key: String) -> [String] {
        guard let property = resource?[key] as? [String: Any] else { return [] }
        if let values = property["value"] as? [String: Any] {
            guard isWritable(property) else { return [] }
            return (values["w"] as? [String]) ?? (values["write"] as? [String]) ?? []
        }
        return []
    }

    private static func isWritable(_ property: [String: Any]) -> Bool {
        if let modes = property["mode"] as? [String] { return modes.contains("w") }
        if let modes = property["mode"] as? String { return modes.contains("w") }
        return false
    }

    private static func temperatureEntries(from value: Any?) -> [[String: Any]] {
        if let dictionary = value as? [String: Any] { return [dictionary] }
        return value as? [[String: Any]] ?? []
    }

    private static func temperatureTarget(from entry: [String: Any], key: String) -> TemperatureTarget? {
        guard let property = entry[key] as? [String: Any], isWritable(property) else { return nil }
        let values = property["value"] as? [String: Any]
        let writable = (values?["w"] as? [String: Any]) ?? (values?["write"] as? [String: Any])
        var range: (min: Double, max: Double)?
        if let writable, let min = writable.double("min"), let max = writable.double("max") {
            range = (min, max)
        }
        return TemperatureTarget(key: key, range: range)
    }

    private static func temperatureRange(from value: Any?) -> (min: Double, max: Double)? {
        let entries = temperatureEntries(from: value)
        for entry in entries where (entry["unit"] as? String ?? "C").uppercased() == "C" {
            for key in ["targetTemperature", "coolTargetTemperature", "heatTargetTemperature", "autoTargetTemperature"] {
                if let range = temperatureTarget(from: entry, key: key)?.range { return range }
            }
            if let min = entry.double("minTargetTemperature"), let max = entry.double("maxTargetTemperature") {
                return (min, max)
            }
        }
        return nil
    }

    private static func pretty(_ value: Double) -> String { value == value.rounded() ? String(Int(value)) : String(value) }
}

private extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func bool(_ key: String) -> Bool? {
        if let value = self[key] as? Bool { return value }
        if let value = self[key] as? NSNumber { return value.boolValue }
        return nil
    }
}
