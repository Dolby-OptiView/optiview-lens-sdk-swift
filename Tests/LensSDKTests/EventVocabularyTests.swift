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
        // Lens's own keys; the catalog's `kind: standard` entries are CTA-5004-B's, travelling bare.
        return keys.filter { $0["kind"] as? String != "standard" }.map { entry in
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

    private func registryJson(_ path: String) throws -> [[String: Any]] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/spec/registry/\(path).json")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return root[path.hasPrefix("keys") ? "keys" : "events"] as! [[String: Any]]
    }

    /// A registry name as a Swift case name: `MPEG-DASH` → `mpegDash`, `LowLatencyLive` → `lowLatencyLive`.
    private func caseName(_ name: String) -> String {
        let parts = name.split(separator: "-").enumerated().map { index, part -> String in
            let word = part.allSatisfy(\.isUppercase) ? part.lowercased() : String(part)
            return index == 0
                ? word.prefix(1).lowercased() + word.dropFirst()
                : word.prefix(1).uppercased() + word.dropFirst()
        }
        return parts.joined()
    }

    func testStampsOnlyCta5004BKeysTheVendoredRegistryListsAsStandard() throws {
        let standard = Set(
            try registryJson("keys/lens").filter { $0["kind"] as? String == "standard" }
                .map { $0["key"] as! String })
        XCTAssertEqual(Encoding.specKeys.subtracting(standard), [])
    }

    func testNamesKeysEventsAndTokenValuesAsTheVendoredRegistryDoes() throws {
        let catalog = Dictionary(
            uniqueKeysWithValues: try registryJson("keys/lens").map { ($0["key"] as! String, $0) })
        for key in CmcdKey.allCases {
            XCTAssertEqual(catalog[key.rawValue]?["fullName"] as? String, "\(key)", key.rawValue)
        }
        let events = try registryJson("events/lens").filter { $0["kind"] as? String == "standard" }
        XCTAssertEqual(
            Dictionary(
                uniqueKeysWithValues: events.map {
                    ($0["fullName"] as! String, $0["event"] as! String)
                }
            ),
            Dictionary(
                uniqueKeysWithValues: CmcdEvent.allCases.filter { $0 != .customEvent }.map {
                    ("\($0)", $0.rawValue)
                }))
        func values(_ key: String) -> [String: String] {
            let entries = catalog[key]?["values"] as? [String: String] ?? [:]
            return Dictionary(uniqueKeysWithValues: entries.map { (caseName($1), $0) })
        }
        func cases<T: CaseIterable & RawRepresentable>(_: T.Type) -> [String: String]
        where T.RawValue == String {
            Dictionary(uniqueKeysWithValues: T.allCases.map { ("\($0)", $0.rawValue) })
        }
        XCTAssertEqual(values("sta"), cases(PlayerState.self))
        XCTAssertEqual(values("sf"), cases(StreamFormat.self))
        XCTAssertEqual(values("st"), cases(StreamType.self))
    }

    func testLensTokenKeysMatchTheVendoredRegistry() throws {
        let expected = Set(try registryKeys().filter { $0.type == "token" }.map(\.key))
        XCTAssertEqual(Encoding.lensTokenKeys, expected)
    }
}
