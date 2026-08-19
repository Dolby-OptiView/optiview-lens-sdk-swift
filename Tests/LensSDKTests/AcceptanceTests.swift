import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LensSDK

/// The v0.1.0 acceptance bar, mirrored from the web reference: exactly what
/// the Ads SDK will do, end to end, through the real URL-loading layer. Spec
/// validity is covered transitively — the wire bytes are golden-locked to the
/// web output, which CI validates with the SVTA validator (docs/testing.md).
final class AcceptanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ReceiverProtocol.self)
        ReceiverProtocol.reset()
        TransportRuntime.ingestOverride = "http://mock.lens/ingest"
    }

    override func tearDown() {
        TransportRuntime.ingestOverride = nil
        TransportRuntime.resetSnRegistryForTesting()
        Lens.resetConfigurationForTesting()
        URLProtocol.unregisterClass(ReceiverProtocol.self)
        super.tearDown()
    }

    private func waitForRequests(_ count: Int, path: String, timeout: TimeInterval = 3) -> [ReceiverProtocol.Captured] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matching = ReceiverProtocol.snapshot().filter { $0.path == path }
            if matching.count >= count { return matching }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return ReceiverProtocol.snapshot().filter { $0.path == path }
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map {
            String(text[Range($0.range(at: 1), in: text)!])
        }
    }

    private func sequenceNumber(in body: String, json: Bool = false) -> Int {
        let pattern = json ? "\"sn\":([0-9]+)" : "sn=([0-9]+)"
        return Int(matches(pattern, in: body).first!)!
    }

    func testRunsTheAdLifecycleIngestOrderedPrefixedCmcdCustomerFilteredShortKeyedJson() throws {
        let lens = try Lens.join(LensJoinOptions(
            namespace: "ads",
            destinations: [LensDestination(
                url: "http://mock.lens/adops",
                filter: LensDestinationFilter(namespaces: ["ads"]),
                format: .json
            )]
        ))
        lens.startSession()
        lens.emit(.adBreakStart, payload: LensPayload(custom: ["pod": "pre-1"]))
        lens.emit(.adStart, payload: LensPayload(custom: ["ad": "ad-123", "creative": "cr-9"]))
        lens.emit(.adEnd, payload: LensPayload(custom: ["ad": "ad-123"]))
        lens.emitCustom("adBreakAdded", payload: LensPayload(custom: ["count": 2]))
        lens.emit(.adBreakEnd, payload: LensPayload(custom: ["pod": "pre-1"]))
        lens.endSession()

        // Order by sn; POST arrival order is not guaranteed.
        let ingest = waitForRequests(5, path: "/ingest").sorted {
            sequenceNumber(in: $0.body) < sequenceNumber(in: $1.body)
        }
        XCTAssertEqual(ingest.count, 5)
        XCTAssertTrue(ingest.allSatisfy { $0.contentType == "application/cmcd" })
        let bodies = ingest.map(\.body).joined(separator: "\n")
        XCTAssertEqual(matches("e=([a-z]+)", in: bodies), ["abs", "as", "ae", "ce", "abe"])
        XCTAssertEqual(matches("sn=([0-9]+)", in: bodies), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(Set(matches("sid=\"([^\"]+)\"", in: bodies)).count, 1)
        XCTAssertTrue(bodies.contains("com.dolby.optiview-ad=\"ad-123\""))
        XCTAssertTrue(bodies.contains("cen=\"adBreakAdded\""))

        // The customer's ad-ops hook: same events, short keys, no prefix anywhere.
        let adops = waitForRequests(5, path: "/adops").sorted {
            sequenceNumber(in: $0.body, json: true) < sequenceNumber(in: $1.body, json: true)
        }
        XCTAssertEqual(adops.count, 5)
        XCTAssertTrue(adops.allSatisfy { $0.contentType == "application/json" })
        XCTAssertTrue(adops.allSatisfy { !$0.body.contains("com.dolby.optiview-") })
        XCTAssertEqual(matches("\"e\":\"([a-z]+)\"", in: adops.map(\.body).joined(separator: "\n")), ["abs", "as", "ae", "ce", "abe"])
        XCTAssertTrue(adops.contains { $0.body.contains("\"ad\":\"ad-123\"") })
    }

    func testKeepsASecondProductOutOfTheCustomerFilterAndOnTheSameMachinery() throws {
        let ads = try Lens.join(LensJoinOptions(
            namespace: "ads",
            destinations: [LensDestination(
                url: "http://mock.lens/adops",
                filter: LensDestinationFilter(namespaces: ["ads"]),
                format: .json
            )]
        ))
        let live = try Lens.join(LensJoinOptions(namespace: "live"))
        ads.startSession()
        live.startSession()
        ads.emit(.adStart)
        live.emitCustom("fallback", payload: LensPayload(custom: ["endpoint": 2]))
        ads.endSession()
        live.endSession()

        let ingest = waitForRequests(2, path: "/ingest")
        let namespaces = Set(matches("com.dolby.optiview-ns=\"([a-z]+)\"", in: ingest.map(\.body).joined(separator: "\n")))
        XCTAssertEqual(namespaces, ["ads", "live"])

        let adops = waitForRequests(1, path: "/adops")
        XCTAssertEqual(adops.count, 1)
        XCTAssertTrue(adops[0].body.contains("\"ns\":\"ads\""))
    }
}
