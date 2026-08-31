import XCTest

@testable import LensSDK

/// Each platform declares the CMCD event tokens by hand; this pins the Swift
/// declarations to conformance/fixtures/event-vocabulary.json so a missing
/// token or a wrong wire code fails here instead of drifting silently.
final class EventVocabularyTests: XCTestCase {
    private struct RegistryKey {
        let key: String
        let type: String
        /// The registry's wire abbreviation → full value maps.
        let values: [String: String]
        let reservedValues: [String: String]
    }

    private func registryKeys() throws -> [RegistryKey] {
        let registryUrl = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/spec/registry/keys/lens.json")
        let data = try Data(contentsOf: registryUrl)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let keys = root["keys"] as! [[String: Any]]
        return keys.map { entry in
            RegistryKey(
                key: entry["key"] as! String,
                type: entry["type"] as! String,
                values: entry["values"] as? [String: String] ?? [:],
                reservedValues: entry["reservedValues"] as? [String: String] ?? [:]
            )
        }
    }

    func testDeclaredTokensMatchTheSharedVocabularyExactly() throws {
        let fixtureUrl = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/event-vocabulary.json")
        let data = try Data(contentsOf: fixtureUrl)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let tokens = root["tokens"] as! [String: String]
        XCTAssertEqual(LensEventVocabulary.declaredTokens, tokens)
    }

    func testLensReservedKeysMatchTheVendoredRegistry() throws {
        let expected = Set(try registryKeys().map(\.key).filter { $0 != "ns" })
        XCTAssertEqual(Validation.lensReserved, expected)
    }

    func testEmittedTokenValuesStayInsideTheRegistryVocabulary() throws {
        let emitted = [
            "p": Set(["ios", "tvos"]),
            "dc": Set([
                EnvironmentRuntime.deviceClasses.desktop,
                EnvironmentRuntime.deviceClasses.mobile,
                EnvironmentRuntime.deviceClasses.tablet,
                EnvironmentRuntime.deviceClasses.tv,
            ]),
        ]
        for entry in try registryKeys().filter({ $0.type == "token" }) {
            let values = try XCTUnwrap(emitted[entry.key])
            XCTAssertTrue(values.isSubset(of: Set(entry.values.values)))
            XCTAssertTrue(values.isDisjoint(with: Set(entry.reservedValues.values)))
        }
    }

    func testTokenValuesAreAbbreviatedExactlyAsTheRegistryMapsThem() throws {
        for entry in try registryKeys().filter({ $0.type == "token" }) {
            let expected = Dictionary(uniqueKeysWithValues: entry.values.map { ($1, $0) })
            XCTAssertEqual(Encoding.tokenAbbreviations[entry.key], expected)
        }
    }

    func testLensTokenKeysMatchTheVendoredRegistry() throws {
        let expected = Set(try registryKeys().filter { $0.type == "token" }.map(\.key))
        XCTAssertEqual(Encoding.lensTokenKeys, expected)
    }
}
