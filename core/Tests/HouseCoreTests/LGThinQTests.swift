import Foundation
import XCTest
@testable import HouseCore

@MainActor
final class LGThinQTests: XCTestCase {
    func testIndiaUsesKICAndUnknownCountriesAreRejected() {
        XCTAssertEqual(LGThinQService.region(for: "in"), "kic")
        XCTAssertEqual(LGThinQService.region(for: " IN "), nil)
        XCTAssertNil(LGThinQService.region(for: "US"))
    }

    func testProfileAndStateMapToHouseControlVocabulary() {
        let profile = LGThinQService.profile(from: Self.profileJSON)
        XCTAssertEqual(profile.modes, ["cool": "COOL", "auto": "AUTO", "fan": "FAN_ONLY"])
        XCTAssertEqual(profile.fans, ["auto": "AUTO", "low": "LOW", "high": "HIGH"])
        XCTAssertEqual(profile.range?.min, 16)
        XCTAssertEqual(profile.range?.max, 30)
        XCTAssertTrue(profile.swing)
        XCTAssertTrue(profile.eco)

        let reading = LGThinQService.reading(from: [
            "operation": ["airConOperationMode": "POWER_ON"],
            "airConJobMode": ["currentJobMode": "COOL"],
            "temperatureInUnits": [["unit": "C", "currentTemperature": 27.0, "targetTemperature": 23.0]],
            "airFlow": ["windStrength": "HIGH"],
            "windDirection": ["rotateUpDown": true],
            "powerSave": ["powerSaveEnabled": false],
        ], profile: profile)
        XCTAssertEqual(reading.ac?["on"] as? Bool, true)
        XCTAssertEqual(reading.ac?["mode"] as? String, "cool")
        XCTAssertEqual(reading.ac?["target"] as? Double, 23)
        XCTAssertEqual(reading.ac?["roomTemp"] as? Double, 27)
        XCTAssertEqual(reading.ac?["fan"] as? String, "high")
        XCTAssertEqual(reading.ac?["swing"] as? String, "swing")
        XCTAssertEqual(reading.features?["modes"] as? [String], ["cool", "fan", "auto"])
        XCTAssertEqual(reading.features?["fans"] as? [String], ["auto", "low", "high"])
        XCTAssertEqual(reading.features?["eco"] as? Bool, true)
    }

    func testDirectTransportDiscoversReadsAndControlsAnIndiaAC() async throws {
        let transport = FakeLGTransport()
        let device: [String: Any] = [
            "deviceId": "ac-1",
            "deviceInfo": [
                "deviceType": "DEVICE_AIR_CONDITIONER", "alias": "Bedroom AC", "modelName": "RSNQ19KWZE",
            ],
            "online": true,
        ]
        transport.enqueue([device])
        transport.enqueue([device])
        transport.enqueue(Self.profileJSON)
        transport.enqueue([
            "operation": ["airConOperationMode": "POWER_ON"],
            "airConJobMode": ["currentJobMode": "COOL"],
            "temperatureInUnits": [["unit": "C", "currentTemperature": 26.0, "targetTemperature": 24.0]],
            "airFlow": ["windStrength": "LOW"],
        ])
        transport.enqueue([:])

        let service = LGThinQService(vault: MemorySecretStore(), transport: transport)
        try await service.connect(country: "IN", token: "test-token")
        XCTAssertTrue(service.isConnected)
        XCTAssertEqual(service.info["region"] as? String, "kic")

        let devices = try await service.devices()
        XCTAssertEqual(devices.map(\.name), ["Bedroom AC"])
        XCTAssertEqual(devices.first?.kind, .ac)
        XCTAssertEqual(devices.first?.range?.min, 16)

        let reading = try await service.read(["ac-1"])["ac-1"]
        XCTAssertEqual(reading?.ac?["target"] as? Double, 24)
        XCTAssertEqual(reading?.ac?["fan"] as? String, "low")

        try await service.send(kind: .ac, id: "ac-1",
                               patch: ["mode": "cool", "target": 23.0, "fan": "high"], state: [:])
        let request = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-country"), "IN")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-conditional-control"), "true")
        let body = try XCTUnwrap(request.httpBody).jsonObject() as? [String: Any]
        XCTAssertEqual((body?["airConJobMode"] as? [String: Any])?["currentJobMode"] as? String, "COOL")
        XCTAssertEqual((body?["temperatureInUnits"] as? [String: Any])?["targetTemperature"] as? Double, 23)
        XCTAssertEqual((body?["airFlow"] as? [String: Any])?["windStrength"] as? String, "HIGH")
    }

    private static let profileJSON: [String: Any] = [
        "property": [
            "airConJobMode": ["currentJobMode": ["mode": ["r", "w"], "value": ["r": ["COOL", "AUTO", "FAN_ONLY"], "w": ["COOL", "AUTO", "FAN_ONLY"]]]],
            "operation": ["airConOperationMode": ["mode": ["r", "w"], "value": ["r": ["POWER_ON", "POWER_OFF"], "w": ["POWER_ON", "POWER_OFF"]]]],
            "airFlow": ["windStrength": ["mode": ["r", "w"], "value": ["r": ["AUTO", "LOW", "HIGH"], "w": ["AUTO", "LOW", "HIGH"]]]],
            "temperatureInUnits": [[
                "unit": "C",
                "targetTemperature": ["mode": ["r", "w"], "value": ["r": ["min": 16, "max": 30], "w": ["min": 16, "max": 30]]],
            ]],
            "windDirection": ["rotateUpDown": ["mode": ["r", "w"]]],
            "powerSave": ["powerSaveEnabled": ["mode": ["r", "w"]]],
        ],
    ]
}

@MainActor
private final class FakeLGTransport: LGThinQTransport {
    var requests: [URLRequest] = []
    private var responses: [Data] = []

    func enqueue(_ response: Any) {
        let data = try! JSONSerialization.data(withJSONObject: ["response": response])
        responses.append(data)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let response = responses.removeFirst()
        return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private extension Data {
    func jsonObject() throws -> Any { try JSONSerialization.jsonObject(with: self) }
}
