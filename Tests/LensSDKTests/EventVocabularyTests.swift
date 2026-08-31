import XCTest

@testable import LensSDK

/// Each platform declares the CMCD event tokens by hand; this pins the Swift
/// declarations to conformance/fixtures/event-vocabulary.json so a missing
/// token or a wrong wire code fails here instead of drifting silently.
final class EventVocabularyTests: XCTestCase {
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
}
