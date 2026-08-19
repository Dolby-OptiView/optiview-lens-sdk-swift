import XCTest
@testable import LensSDK

final class LensTests: XCTestCase {
    private struct Delivery {
        let destination: LensDestination
        let event: LensEvent
    }

    private var delivered: [Delivery] = []
    private let ingest = LensDestination(url: "https://example.test/ingest")

    private func captureSink() {
        delivered = []
        Lens.sinkForTesting = { [self] destination, event in
            delivered.append(Delivery(destination: destination, event: event))
        }
    }

    override func tearDown() {
        Lens.sinkForTesting = nil
        Lens.resetConfigurationForTesting()
        super.tearDown()
    }

    // MARK: join

    func testValidatesTheNamespace() {
        XCTAssertThrowsError(try Lens.join(LensJoinOptions(namespace: "")))
    }

    func testStartsWithoutAnActiveSession() throws {
        let lens = try Lens.join(LensJoinOptions(namespace: "ads"))
        XCTAssertNil(lens.session)
    }

    func testFirstJoinLocksProductionBackend() throws {
        _ = try Lens.join(LensJoinOptions(namespace: "ads"))
        XCTAssertThrowsError(try Lens.useDevelopmentBackend(url: "https://dev-ingest.test/events")) { error in
            XCTAssertEqual(error as? LensError, .invalidOptions("Lens: backend is already locked to 'production'"))
        }
    }

    func testRejectsRegisteringADifferentDevIngestUrl() throws {
        try Lens.useDevelopmentBackend(url: "https://dev-a.test/events")
        XCTAssertThrowsError(try Lens.useDevelopmentBackend(url: "https://dev-b.test/events")) { error in
            XCTAssertEqual(error as? LensError, .invalidOptions("Lens: a development ingest URL is already registered"))
        }
        XCTAssertNoThrow(try Lens.useDevelopmentBackend(url: "https://dev-a.test/events"))
    }

    func testRepeatingTheSameBackendConfigurationIsANoOp() throws {
        try Lens.useDevelopmentBackend(url: "https://dev-ingest.test/events")
        XCTAssertNoThrow(try Lens.useDevelopmentBackend(url: "https://dev-ingest.test/events"))
        XCTAssertThrowsError(try Lens.configure(LensConfigureOptions(backend: .production)))
    }

    // MARK: sessions

    func testStartSessionActivatesASessionAndEmitsCarryItsSid() throws {
        captureSink()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        let session = lens.startSession()
        XCTAssertEqual(lens.session?.sessionId, session.sessionId)
        lens.emit(.adStart)
        XCTAssertEqual(delivered.first?.event.session.sessionId, session.sessionId)
    }

    func testUsesAnExternallySteeredSessionIdWhenGiven() throws {
        let lens = try Lens.join(LensJoinOptions(namespace: "ads"))
        let session = lens.startSession(LensStartSessionOptions(sessionId: "discovery-sid-1"))
        XCTAssertEqual(session.sessionId, "discovery-sid-1")
    }

    func testRollsTheSessionWhenStartedWhileActive() throws {
        captureSink()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        let first = lens.startSession()
        let second = lens.startSession()
        XCTAssertNotEqual(first.sessionId, second.sessionId)
        lens.emit(.adStart)
        XCTAssertEqual(delivered.first?.event.session.sessionId, second.sessionId)
    }

    func testDropsEmitsWhenNoSessionIsActive() throws {
        captureSink()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.emit(.adStart)
        lens.startSession()
        lens.endSession()
        XCTAssertNil(lens.session)
        lens.emit(.adEnd)
        XCTAssertEqual(delivered.count, 0)
    }

    func testKeepsDestinationsAcrossSessionRolls() throws {
        captureSink()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        lens.emit(.adStart)
        lens.startSession()
        lens.emit(.adStart)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertTrue(delivered.allSatisfy { $0.destination.url == ingest.url })
    }

    // MARK: emit

    func testStampsTheEnvelopeWithWireTypeBoundNamespaceTimestampSessionAndKeys() throws {
        captureSink()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        lens.emit(.adStart, payload: LensPayload(custom: ["ad": "ad-1"]))
        XCTAssertEqual(delivered.count, 1)
        let event = try XCTUnwrap(delivered.first).event
        XCTAssertEqual(event.type, "as")
        XCTAssertNil(event.customName)
        XCTAssertEqual(event.namespace, "ads")
        XCTAssertEqual(event.keys?["ad"] as? String, "ad-1")
        XCTAssertGreaterThanOrEqual(event.timestamp, before)
        XCTAssertEqual(event.session.sessionId, lens.session?.sessionId)
    }

    private func captureViolations() -> () -> [String] {
        nonisolated(unsafe) var violations: [String] = []
        Lens.usageViolation = { violations.append($0) }
        return { violations }
    }

    func testFailsOnRegisteredCmcdNamesInCustomMaps() throws {
        captureSink()
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest], strict: true))
        lens.startSession()
        lens.emit(.adStart, payload: LensPayload(custom: ["sid": "x"]))
        lens.emitCustom("adBreakAdded", payload: LensPayload(custom: ["pt": 3]))
        lens.emit(.adStart, payload: LensPayload(custom: ["ns": "live"]))
        XCTAssertEqual(violations().count, 3)
        XCTAssertTrue(violations().allSatisfy { $0.contains("registered CMCD key") })
        XCTAssertEqual(delivered.count, 0)
    }

    func testRejectsInvalidCustomKeyNamesLoudly() throws {
        captureSink()
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest], strict: true))
        lens.startSession()
        lens.emit(.adStart, payload: LensPayload(custom: ["ad_1": "x"]))
        lens.emit(.adStart, payload: LensPayload(custom: ["adBreak": "x"]))
        lens.emit(.adStart, payload: LensPayload(custom: [String(repeating: "k", count: 46): "x"]))
        XCTAssertEqual(violations().count, 3)
        XCTAssertTrue(violations()[0].contains("invalid custom key"))
        XCTAssertTrue(violations()[2].contains("exceeds 45 characters"))
        XCTAssertEqual(delivered.count, 0)
        lens.emit(.adStart, payload: LensPayload(custom: ["ad-1": "ok"]))
        XCTAssertEqual(delivered.first?.event.keys?["ad-1"] as? String, "ok")
    }

    func testRejectsInvalidCustomEventNamesLoudly() throws {
        captureSink()
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest], strict: true))
        lens.startSession()
        lens.emitCustom("com.example.adBreakAdded")
        lens.emitCustom(String(repeating: "x", count: 65))
        XCTAssertEqual(violations().count, 2)
        XCTAssertEqual(delivered.count, 0)
        lens.emitCustom("adBreakAdded")
        XCTAssertEqual(delivered.count, 1)
    }

    func testDefaultModeDropsTheOffendingUnitInsteadOfFailing() throws {
        captureSink()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        lens.emit(.adStart, payload: LensPayload(custom: ["ad_1": "nope", "ad": "ad-1"]))
        lens.emitCustom("com.example.bad")
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.event.keys?.count, 1)
        XCTAssertEqual(delivered.first?.event.keys?["ad"] as? String, "ad-1")
    }

    func testSetupProblemsAlwaysFail() throws {
        XCTAssertThrowsError(try Lens.join(LensJoinOptions(namespace: String(repeating: "x", count: 65))))
        XCTAssertThrowsError(try Lens.join(LensJoinOptions(namespace: "bad\nname")))
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(LensJoinOptions(namespace: "ads"))
        lens.startSession(LensStartSessionOptions(sessionId: "bad\nsid"))
        lens.startSession(LensStartSessionOptions(sessionId: String(repeating: "s", count: 65)))
        XCTAssertEqual(violations().count, 2)
    }

    func testLowersCustomEventsToCeWithTheCustomName() throws {
        captureSink()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        lens.emitCustom("adBreakAdded", payload: LensPayload(custom: ["count": 2]))
        XCTAssertEqual(delivered.count, 1)
        let event = try XCTUnwrap(delivered.first).event
        XCTAssertEqual(event.type, "ce")
        XCTAssertEqual(event.customName, "adBreakAdded")
        XCTAssertEqual(event.keys?["count"] as? Int, 2)
    }

    // MARK: destinations

    func testFiltersByNamespaceWireTypeAndCustomName() throws {
        captureSink()
        let adsOnly = LensDestination(
            url: "https://adops.test/hook",
            filter: LensDestinationFilter(namespaces: ["ads"], events: ["as", "adBreakAdded"])
        )
        let ads = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [adsOnly]))
        ads.startSession()
        ads.emit(.adStart)
        ads.emit(.adEnd)
        ads.emitCustom("adBreakAdded")
        ads.emitCustom("other")
        let live = try Lens.join(LensJoinOptions(namespace: "live", destinations: [adsOnly]))
        live.startSession()
        live.emit(.adStart)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered.first?.event.type, "as")
        XCTAssertEqual(delivered.last?.event.customName, "adBreakAdded")
        XCTAssertTrue(delivered.allSatisfy { $0.event.namespace == "ads" })
    }

    func testDeliversToEveryConfiguredDestination() throws {
        captureSink()
        let lens = try Lens.join(LensJoinOptions(
            namespace: "ads",
            destinations: [LensDestination(url: "https://a.test"), LensDestination(url: "https://b.test")]
        ))
        lens.startSession()
        lens.emit(.adStart)
        XCTAssertEqual(delivered.map(\.destination.url).sorted(), ["https://a.test", "https://b.test"])
    }

    // MARK: consent

    func testDefaultsToGrantedAndCanBeIgnoredEntirely() throws {
        captureSink()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        lens.emit(.adStart)
        XCTAssertEqual(delivered.count, 1)
    }

    func testDropsEventsWhileDeniedAndResumesWhenRegranted() throws {
        captureSink()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        lens.setConsent(.denied)
        lens.emit(.adStart)
        XCTAssertEqual(delivered.count, 0)
        lens.setConsent(.granted)
        lens.emit(.adEnd)
        XCTAssertEqual(delivered.count, 1)
    }

    // MARK: dispose

    func testEndsTheSessionAndMakesTheHandleInert() throws {
        captureSink()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        lens.dispose()
        XCTAssertNil(lens.session)
        lens.startSession()
        lens.emit(.adStart)
        XCTAssertNil(lens.session)
        XCTAssertEqual(delivered.count, 0)
    }
}
