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

    /// The heartbeat cadence, driven by hand.
    private final class Ticker {
        let intervalMs: Int64
        let tick: () -> Void
        var stopped = false

        init(intervalMs: Int64, tick: @escaping () -> Void) {
            self.intervalMs = intervalMs
            self.tick = tick
        }
    }

    private var tickers: [Ticker] = []
    private let defaultTicker = Lens.ticker

    private func captureTickers() {
        tickers = []
        Lens.ticker = { [self] intervalMs, tick in
            let ticker = Ticker(intervalMs: intervalMs, tick: tick)
            tickers.append(ticker)
            return { ticker.stopped = true }
        }
    }

    private var running: [Ticker] { tickers.filter { !$0.stopped } }

    // This suite is about API semantics, not delivery — no test here may
    // touch the network (its destinations don't resolve anywhere real).
    override func setUp() {
        super.setUp()
        TransportRuntime.postOverride = { _, _, _ in }
    }

    override func tearDown() {
        TransportRuntime.postOverride = nil
        Lens.sinkForTesting = nil
        Lens.ticker = defaultTicker
        Lens.resetConfigurationForTesting()
        super.tearDown()
    }

    // MARK: join

    func testValidatesTheNamespace() {
        XCTAssertThrowsError(try Lens.join(LensJoinOptions(namespace: "")))
    }

    func testStartsWithoutAnActiveSession() throws {
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        XCTAssertNil(lens.session)
    }

    func testFirstJoinLocksProductionBackend() throws {
        _ = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        XCTAssertThrowsError(try Lens.useDevelopmentBackend(url: "https://dev-ingest.test/events"))
        { error in
            XCTAssertEqual(
                error as? LensError,
                .invalidOptions("Lens: backend is already locked to 'production'"))
        }
    }

    func testRejectsRegisteringADifferentDevIngestUrl() throws {
        try Lens.useDevelopmentBackend(url: "https://dev-a.test/events")
        XCTAssertThrowsError(try Lens.useDevelopmentBackend(url: "https://dev-b.test/events")) {
            error in
            XCTAssertEqual(
                error as? LensError,
                .invalidOptions("Lens: a development ingest URL is already registered"))
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
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        let session = lens.startSession()
        XCTAssertEqual(lens.session?.sessionId, session.sessionId)
        lens.emit(.adStart)
        XCTAssertEqual(delivered.first?.event.session.sessionId, session.sessionId)
    }

    func testUsesAnExternallySteeredSessionIdWhenGiven() throws {
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        let session = lens.startSession(LensStartSessionOptions(sessionId: "discovery-sid-1"))
        XCTAssertEqual(session.sessionId, "discovery-sid-1")
    }

    func testRollsTheSessionWhenStartedWhileActive() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        let first = lens.startSession()
        let second = lens.startSession()
        XCTAssertNotEqual(first.sessionId, second.sessionId)
        // The roll ends the first session, so it quits.
        XCTAssertEqual(delivered[0].event.type, "ps")
        XCTAssertEqual(delivered[0].event.playbackState, "q")
        XCTAssertEqual(delivered[0].event.session.sessionId, first.sessionId)
        lens.emit(.adStart)
        XCTAssertEqual(delivered[1].event.session.sessionId, second.sessionId)
    }

    func testDropsEmitsWhenNoSessionIsActive() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        lens.emit(.adStart)
        lens.startSession()
        lens.endSession()
        XCTAssertNil(lens.session)
        lens.emit(.adEnd)
        // Only the session's own quit report went out — both emits were dropped.
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].event.type, "ps")
        XCTAssertEqual(delivered[0].event.namespace, "lens")
        XCTAssertEqual(delivered[0].event.playbackState, "q")
    }

    func testKeepsDestinationsAcrossSessionRolls() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart)
        lens.startSession()
        lens.emit(.adStart)
        XCTAssertEqual(delivered.count, 3)  // the roll's quit rides along
        XCTAssertTrue(delivered.allSatisfy { $0.destination.url == ingest.url })
    }

    // MARK: emit

    func testStampsTheEnvelopeWithWireTypeBoundNamespaceTimestampSessionAndKeys() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        lens.startSession()
        let before = Int64(Date().timeIntervalSince1970 * 1000)
        lens.emit(.adStart, payload: LensAdPayload(custom: ["ad": "ad-1"]))
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
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], strict: true, heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart, payload: LensAdPayload(custom: ["sid": "x"]))
        lens.emitCustom("adBreakAdded", payload: LensPayload(custom: ["pt": 3]))
        lens.emit(.adStart, payload: LensAdPayload(custom: ["ns": "live"]))
        XCTAssertEqual(violations().count, 3)
        XCTAssertTrue(violations().allSatisfy { $0.contains("registered CMCD key") })
        XCTAssertEqual(delivered.count, 0)
    }

    func testFailsOnTheKeysLensStampsItself() throws {
        captureSink()
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], strict: true, heartbeatMs: 0))
        lens.startSession()
        let keys = EnvironmentRuntime.environmentKeys + ["u"]
        for key in keys {
            lens.emit(.adStart, payload: LensAdPayload(custom: [key: "x"]))
        }
        XCTAssertEqual(violations().count, keys.count)
        XCTAssertTrue(violations().allSatisfy { $0.contains("Lens-owned key") })
        XCTAssertEqual(delivered.count, 0)
    }

    func testRejectsInvalidCustomKeyNamesLoudly() throws {
        captureSink()
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], strict: true, heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart, payload: LensAdPayload(custom: ["ad-1": "x"]))
        lens.emit(.adStart, payload: LensAdPayload(custom: ["adBreak": "x"]))
        lens.emit(
            .adStart, payload: LensAdPayload(custom: [String(repeating: "k", count: 46): "x"]))
        XCTAssertEqual(violations().count, 3)
        XCTAssertTrue(violations()[0].contains("invalid custom key"))
        XCTAssertTrue(violations()[2].contains("exceeds 45 characters"))
        XCTAssertEqual(delivered.count, 0)
        lens.emit(.adStart, payload: LensAdPayload(custom: ["ad_1": "ok"]))
        XCTAssertEqual(delivered.first?.event.keys?["ad_1"] as? String, "ok")
    }

    func testDropsInvalidCustomTokenValuesByDefaultAndFailsInStrictMode() throws {
        captureSink()
        let invalid = [
            LensToken(value: "1c"),
            LensToken(value: ""),
            LensToken(value: "a\nb"),
            LensToken(value: "c\n"),
            LensToken(value: "c\r\n"),
            LensToken(value: "ab\r"),
            LensToken(value: "c\""),
            LensToken(value: String(repeating: "c", count: 65)),
        ]
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        lens.startSession()
        for (index, value) in invalid.enumerated() {
            lens.emit(
                .adStart,
                payload: LensAdPayload(custom: ["bad_\(index)": value, "good": "ok"]))
        }
        XCTAssertEqual(delivered.count, invalid.count)
        XCTAssertTrue(
            delivered.allSatisfy {
                $0.event.keys?.count == 1 && $0.event.keys?["good"] as? String == "ok"
            })

        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let strict = try Lens.join(
            LensJoinOptions(
                namespace: "strict-ads", destinations: [ingest], strict: true, heartbeatMs: 0))
        strict.startSession()
        for value in invalid {
            strict.emit(.adStart, payload: LensAdPayload(custom: ["ader": value]))
        }
        XCTAssertEqual(violations().count, invalid.count)
        XCTAssertTrue(violations().allSatisfy { $0.contains("custom token value") })
    }

    func testDropsNonFiniteCustomValuesWhileSendingTheEventAndHeartbeat() throws {
        captureSink()
        captureTickers()
        let values = [Double.nan, Double.infinity, -Double.infinity]
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        delivered.removeAll()
        for value in values {
            lens.emit(.adStart, payload: LensAdPayload(custom: ["bad": value, "good": "ok"]))
        }
        XCTAssertEqual(delivered.count, values.count)
        XCTAssertTrue(
            delivered.allSatisfy {
                $0.event.keys?.count == 1 && $0.event.keys?["good"] as? String == "ok"
            })

        delivered.removeAll()
        lens.setHeartbeatPayload(LensPayload(custom: ["bad": Double.nan, "good": "ok"]))
        running[0].tick()
        XCTAssertEqual(delivered.first?.event.keys?["good"] as? String, "ok")
        XCTAssertNil(delivered.first?.event.keys?["bad"])

        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let strict = try Lens.join(
            LensJoinOptions(
                namespace: "strict-ads", destinations: [ingest], strict: true, heartbeatMs: 0))
        strict.startSession()
        for value in values {
            strict.emit(.adStart, payload: LensAdPayload(custom: ["bad": value]))
        }
        strict.setHeartbeatPayload(LensPayload(custom: ["bad": Double.infinity]))
        XCTAssertEqual(violations().count, values.count + 1)
        XCTAssertTrue(violations().allSatisfy { $0.contains("non-finite value") })
    }

    func testRejectsInvalidCustomEventNamesLoudly() throws {
        captureSink()
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], strict: true, heartbeatMs: 0))
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
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart, payload: LensAdPayload(custom: ["ad-1": "nope", "ad": "ad-1"]))
        lens.emitCustom("com.example.bad")
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.event.keys?.count, 1)
        XCTAssertEqual(delivered.first?.event.keys?["ad"] as? String, "ad-1")
    }

    func testSetupProblemsAlwaysFail() throws {
        XCTAssertThrowsError(
            try Lens.join(LensJoinOptions(namespace: String(repeating: "x", count: 65))))
        XCTAssertThrowsError(try Lens.join(LensJoinOptions(namespace: "bad\nname")))
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession(LensStartSessionOptions(sessionId: "bad\nsid"))
        lens.startSession(LensStartSessionOptions(sessionId: String(repeating: "s", count: 65)))
        XCTAssertEqual(violations().count, 2)
    }

    // MARK: content identity

    private func startWithContent(_ lens: LensHandle) -> LensSession {
        lens.startSession(
            LensStartSessionOptions(contentId: "movie-1", streamingFormat: "h", streamType: "v"))
    }

    func testStampsSessionContentIdentityOnEveryReport() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        _ = startWithContent(lens)
        lens.emit(.adBreakStart)
        running[0].tick()
        XCTAssertEqual(delivered.count, 3)
        for delivery in delivered {
            XCTAssertEqual(delivery.event.contentId, "movie-1")
            XCTAssertEqual(delivery.event.streamingFormat, "h")
            XCTAssertEqual(delivery.event.streamType, "v")
        }
    }

    func testFollowsTheAdContentIdentitySequence() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        _ = startWithContent(lens)
        lens.emit(.adBreakStart)
        lens.emit(.adStart, payload: LensAdPayload(contentId: "ad-1"))
        lens.emit(.adEnd)
        lens.emit(.adStart, payload: LensAdPayload(contentId: "ad-2"))
        lens.emit(.adSkip)
        lens.emit(.adBreakEnd)
        XCTAssertEqual(
            delivered.map { $0.event.contentId },
            ["movie-1", "ad-1", "ad-1", "ad-2", "ad-2", "movie-1"])
        XCTAssertTrue(delivered.allSatisfy { $0.event.streamingFormat == "h" })
        XCTAssertTrue(delivered.allSatisfy { $0.event.streamType == "v" })
    }

    func testGenericEventsInsideAnOpenAdSwapCarryTheAdId() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        _ = startWithContent(lens)
        lens.emit(.adStart, payload: LensAdPayload(contentId: "ad-1"))
        lens.emitCustom("quartile")
        lens.emit(.adEnd)
        lens.emitCustom("betweenAds")
        XCTAssertEqual(
            delivered.map { $0.event.contentId }, ["ad-1", "ad-1", "ad-1", "movie-1"])
    }

    func testHeartbeatsAlwaysCarryTheSessionContentId() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        _ = startWithContent(lens)
        lens.emit(.adStart, payload: LensAdPayload(contentId: "ad-1"))
        running[0].tick()
        XCTAssertEqual(delivered.last?.event.type, "t")
        XCTAssertEqual(delivered.last?.event.contentId, "movie-1")
    }

    func testAnUnmatchedAdStartIsBoundedByTheBreakEnd() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        _ = startWithContent(lens)
        lens.emit(.adStart, payload: LensAdPayload(contentId: "ad-1"))
        lens.emit(.adBreakEnd)
        lens.emitCustom("afterBreak")
        XCTAssertEqual(
            delivered.map { $0.event.contentId }, ["ad-1", "movie-1", "movie-1"])
    }

    func testASessionRollClearsAnOpenAdSwap() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        _ = startWithContent(lens)
        lens.emit(.adStart, payload: LensAdPayload(contentId: "ad-1"))
        _ = startWithContent(lens)
        lens.emitCustom("afterRoll")
        XCTAssertEqual(delivered.last?.event.contentId, "movie-1")
    }

    func testEveryAdStartReplacesTheSwapAndNeverInheritsTheLastAd() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        _ = startWithContent(lens)
        lens.emit(.adStart, payload: LensAdPayload(contentId: "ad-1"))
        lens.emit(.adStart, payload: LensAdPayload(contentId: "ad-2"))  // back-to-back in a pod
        lens.emit(.adStart)  // no id — falls back to the session's
        lens.emit(.adEnd)
        XCTAssertEqual(
            delivered.map { $0.event.contentId }, ["ad-1", "ad-2", "movie-1", "movie-1"])
    }

    func testAClosingEventsOwnIdLabelsItWithoutReopeningASwap() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        _ = startWithContent(lens)
        lens.emit(.adEnd, payload: LensAdPayload(contentId: "ad-late"))
        lens.emitCustom("afterLateEnd")
        XCTAssertEqual(
            delivered.map { $0.event.contentId }, ["ad-late", "movie-1"])
    }

    func testTheSidNeverRollsBecauseOfAContentIdChange() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        let session = startWithContent(lens)
        lens.emit(.adStart, payload: LensAdPayload(contentId: "ad-1"))
        lens.emit(.adEnd)
        XCTAssertTrue(delivered.allSatisfy { $0.event.session.sessionId == session.sessionId })
    }

    func testOmittedContentIdentityStaysAbsent() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart)
        XCTAssertNil(delivered.first?.event.contentId)
        XCTAssertNil(delivered.first?.event.streamingFormat)
        XCTAssertNil(delivered.first?.event.streamType)
    }

    func testContentIdentitySetupProblemsAlwaysFail() throws {
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession(
            LensStartSessionOptions(contentId: String(repeating: "c", count: 129)))
        lens.startSession(LensStartSessionOptions(contentId: "bad\ncid"))
        lens.startSession(LensStartSessionOptions(streamingFormat: "x"))
        lens.startSession(LensStartSessionOptions(streamType: "x"))
        XCTAssertEqual(violations().count, 4)
    }

    func testStrictModeFailsOnAnInvalidAdContentId() throws {
        captureSink()
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], strict: true, heartbeatMs: 0))
        _ = startWithContent(lens)
        lens.emit(.adStart, payload: LensAdPayload(contentId: "bad\ncid"))
        XCTAssertEqual(violations().count, 1)
        XCTAssertEqual(delivered.count, 0)
    }

    func testDefaultModeDropsAnInvalidAdContentIdButSendsTheEvent() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        _ = startWithContent(lens)
        lens.emit(.adStart, payload: LensAdPayload(contentId: "bad\ncid"))
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.event.contentId, "movie-1")
    }

    func testLowersCustomEventsToCeWithTheCustomName() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
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
        let ads = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [adsOnly], heartbeatMs: 0))
        ads.startSession()
        ads.emit(.adStart)
        ads.emit(.adEnd)
        ads.emitCustom("adBreakAdded")
        ads.emitCustom("other")
        let live = try Lens.join(
            LensJoinOptions(namespace: "live", destinations: [adsOnly], heartbeatMs: 0))
        live.startSession()
        live.emit(.adStart)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered.first?.event.type, "as")
        XCTAssertEqual(delivered.last?.event.customName, "adBreakAdded")
        XCTAssertTrue(delivered.allSatisfy { $0.event.namespace == "ads" })
    }

    func testDeliversToEveryConfiguredDestination() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads",
                destinations: [
                    LensDestination(url: "https://a.test"), LensDestination(url: "https://b.test"),
                ],
                heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart)
        XCTAssertEqual(
            delivered.map(\.destination.url).sorted(), ["https://a.test", "https://b.test"])
    }

    // MARK: consent

    func testDefaultsToGrantedAndCanBeIgnoredEntirely() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart)
        XCTAssertEqual(delivered.count, 1)
    }

    func testDropsEventsWhileDeniedAndResumesWhenRegranted() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        lens.startSession()
        lens.setConsent(.denied)
        lens.emit(.adStart)
        XCTAssertEqual(delivered.count, 0)
        lens.setConsent(.granted)
        lens.emit(.adEnd)
        XCTAssertEqual(delivered.count, 1)
    }

    // MARK: heartbeat

    func testHeartbeatRunsAtTheSpecDefaultCadenceForTheLifeOfTheSession() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        XCTAssertEqual(running.count, 0)  // no session, no cadence
        let session = lens.startSession()
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running[0].intervalMs, 30_000)
        XCTAssertEqual(delivered.count, 1)  // the cadence opens with a report

        running[0].tick()
        XCTAssertEqual(delivered.count, 2)
        let event = delivered[0].event
        XCTAssertEqual(event.type, "t")
        XCTAssertEqual(event.namespace, "ads")
        XCTAssertNil(event.customName)
        XCTAssertNil(event.keys)
        XCTAssertEqual(event.session.sessionId, session.sessionId)

        lens.endSession()
        XCTAssertEqual(running.count, 0)
    }

    func testHeartbeatIsOffAtZeroAndRejectsCadencesThatAreNotASaneInterval() throws {
        captureTickers()
        let off = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        off.startSession()
        XCTAssertEqual(running.count, 0)

        for heartbeatMs in [Int64(-1), 999, .min] {
            XCTAssertThrowsError(
                try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: heartbeatMs)))
        }
    }

    func testTheLensNamespaceIsReservedAndIntegratorsCannotForgeATimeInterval() throws {
        captureSink()
        XCTAssertThrowsError(try Lens.join(LensJoinOptions(namespace: "lens")))
        XCTAssertThrowsError(try Lens.join(LensJoinOptions(namespace: "LENS")))
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        lens.startSession()
        lens.emitCustom("t")
        XCTAssertEqual(delivered[0].event.type, "ce")
        XCTAssertEqual(delivered[0].event.customName, "t")
        XCTAssertEqual(delivered[0].event.namespace, "ads")
    }

    func testHeartbeatKeepsOneCadenceAcrossASessionRollOnTheNewSid() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        let rolled = lens.startSession()
        XCTAssertEqual(running.count, 1)
        running[0].tick()
        // One per session start, the roll's quit, then the tick.
        XCTAssertEqual(delivered.count, 4)
        XCTAssertEqual(delivered[3].event.session.sessionId, rolled.sessionId)

        lens.dispose()
        XCTAssertEqual(running.count, 0)
    }

    func testHeartbeatGoesSilentWhileConsentIsDenied() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        let stale = running[0]
        delivered.removeAll()  // the session's opening report is not what this is about
        lens.setConsent(.denied)
        XCTAssertEqual(running.count, 0)
        stale.tick()
        XCTAssertEqual(delivered.count, 0)

        lens.setConsent(.granted)
        XCTAssertEqual(running.count, 1)
        running[0].tick()
        XCTAssertEqual(delivered.count, 2)  // the resumed cadence opens with a report
    }

    func testHeartbeatTickerStaysRunningWhenConsentIsReasserted() throws {
        captureTickers()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        let ticker = try XCTUnwrap(running.first)

        lens.setConsent(.granted)

        XCTAssertTrue(running.first === ticker)
    }

    func testHeartbeatReachesCmcdEventTargetsByDefaultAndOtherFormatsOnlyOnRequest() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads",
                destinations: [
                    LensDestination(url: "https://cmcd.test"),
                    LensDestination(url: "https://cmcd-opted-out.test", heartbeat: false),
                    LensDestination(url: "https://adops.test", format: .json),
                    LensDestination(
                        url: "https://adops-opted-in.test", format: .json, heartbeat: true),
                    LensDestination(
                        url: "https://live-only.test",
                        filter: LensDestinationFilter(namespaces: ["live"])),
                ]
            )
        )
        lens.startSession()
        XCTAssertEqual(
            delivered.map(\.destination.url),
            ["https://cmcd.test", "https://adops-opted-in.test"]
        )
    }

    // MARK: heartbeat interval

    func testChangingTheCadenceClosesOutTheRunningIntervalAndBeatsAtTheNewOne() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        delivered.removeAll()  // past the report the session opened with

        lens.setHeartbeatInterval(10_000)

        XCTAssertEqual(delivered.count, 1)  // one report closing the 30s interval
        XCTAssertEqual(delivered[0].event.type, "t")
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running[0].intervalMs, 10_000)

        running[0].tick()
        XCTAssertEqual(delivered.count, 2)
    }

    func testSettingTheCadenceInForceAgainDoesNothingAtAll() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 10_000))
        lens.startSession()
        let ticker = try XCTUnwrap(running.first)
        delivered.removeAll()

        lens.setHeartbeatInterval(10_000)

        XCTAssertTrue(running.first === ticker)  // a pending tick must not be starved
        XCTAssertEqual(delivered.count, 0)
    }

    func testCadenceZeroStopsWithoutAPartingReportAndTheNextValueOpensTheCadenceAgain() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        delivered.removeAll()

        lens.setHeartbeatInterval(0)
        XCTAssertEqual(running.count, 0)
        XCTAssertEqual(delivered.count, 0)  // nothing to close out

        lens.setHeartbeatInterval(5_000)
        XCTAssertEqual(delivered.count, 1)  // starts like a session's cadence does
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(running[0].intervalMs, 5_000)
    }

    func testARejectedCadenceLeavesTheRunningOneAlone() throws {
        captureSink()
        captureTickers()
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        let ticker = try XCTUnwrap(running.first)
        delivered.removeAll()

        for ms in [Int64(-1), 999, .min] {
            lens.setHeartbeatInterval(ms)
        }

        XCTAssertEqual(violations().count, 3)
        XCTAssertTrue(running.first === ticker)
        XCTAssertEqual(delivered.count, 0)
    }

    func testACadenceSetBetweenSessionsHoldsForTheNextOneAndADisposedHandleIgnoresIt() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.setHeartbeatInterval(5_000)  // no session yet: value only, nothing sent
        XCTAssertEqual(running.count, 0)
        XCTAssertEqual(delivered.count, 0)

        lens.startSession()
        XCTAssertEqual(running[0].intervalMs, 5_000)
        XCTAssertEqual(delivered.count, 1)

        lens.dispose()  // ends the live session: the quit report goes out
        lens.setHeartbeatInterval(10_000)
        XCTAssertEqual(running.count, 0)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered[1].event.type, "ps")
    }

    // MARK: heartbeat payload

    func testContributedKeysRideTheReportAlreadyGoingOutStillOnePerTick() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.setHeartbeatPayload(LensPayload(custom: ["pod": "mid-1"]))
        XCTAssertEqual(running.count, 0)  // setting state neither sends nor starts a cadence
        XCTAssertEqual(delivered.count, 0)

        lens.startSession()
        running[0].tick()
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered[0].event.type, "t")
        XCTAssertEqual(delivered[0].event.namespace, "ads")
        XCTAssertEqual(delivered[0].event.keys?["pod"] as? String, "mid-1")

        lens.setHeartbeatPayload(LensPayload(custom: ["pod": "mid-2"]))  // latest write wins
        XCTAssertEqual(delivered.count, 2)
        running[0].tick()
        XCTAssertEqual(delivered[2].event.keys?["pod"] as? String, "mid-2")
    }

    func testAWriteWithNothingValidLeftClearsBackToPlainLiveness() throws {
        captureSink()
        captureTickers()
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        delivered.removeAll()
        var state: LensEventKeys = ["pod": "mid-1"]
        lens.setHeartbeatPayload(LensPayload(custom: state))
        state["pod"] = "mutated-after-the-call"  // value types snapshot by construction
        running[0].tick()
        XCTAssertEqual(delivered[0].event.keys?["pod"] as? String, "mid-1")

        for cleared: LensPayload? in [
            nil, LensPayload(), LensPayload(custom: [:]), LensPayload(custom: ["sid": "forged"]),
        ] {
            lens.setHeartbeatPayload(cleared)
            running[0].tick()
            let event = try XCTUnwrap(delivered.last).event
            XCTAssertEqual(event.namespace, "ads")  // keys come and go; the namespace does not
            XCTAssertNil(event.keys)
        }
        XCTAssertEqual(violations().count, 0)  // default mode warns, never fails
    }

    func testContributedKeysAreHeldToTheEmitPathContract() throws {
        captureSink()
        captureTickers()
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let strict = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], strict: true))
        strict.startSession()
        strict.setHeartbeatPayload(LensPayload(custom: ["sid": "x"]))
        strict.setHeartbeatPayload(LensPayload(custom: ["ns": "live"]))
        strict.setHeartbeatPayload(LensPayload(custom: ["adBreak": "x"]))
        strict.setHeartbeatPayload(LensPayload(custom: [String(repeating: "k", count: 46): "x"]))
        XCTAssertEqual(violations().count, 4)
        running[0].tick()  // nothing invalid ever reaches a report
        XCTAssertEqual(delivered[0].event.namespace, "ads")
        XCTAssertNil(delivered[0].event.keys)

        // Default mode drops the refused key and keeps the rest.
        let lenient = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lenient.startSession()
        lenient.setHeartbeatPayload(LensPayload(custom: ["pod": "mid-1", "ad-1": "nope"]))
        try XCTUnwrap(running.last).tick()
        let event = try XCTUnwrap(delivered.last).event
        XCTAssertEqual(event.keys?.count, 1)
        XCTAssertEqual(event.keys?["pod"] as? String, "mid-1")
    }

    func testContributedKeysSurviveASessionRollButADisposedHandleKeepsNothing() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", destinations: [ingest]))
        lens.startSession()
        lens.setHeartbeatPayload(LensPayload(custom: ["pod": "mid-1"]))
        lens.endSession()
        delivered.removeAll()
        lens.startSession()
        running[0].tick()
        XCTAssertEqual(delivered[0].event.keys?["pod"] as? String, "mid-1")
        XCTAssertEqual(delivered.count, 2)

        lens.dispose()  // ends the live session: the quit report carries the snapshot
        lens.setHeartbeatPayload(LensPayload(custom: ["pod": "mid-2"]))
        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(delivered[2].event.type, "ps")
        XCTAssertEqual(delivered[2].event.namespace, "lens")
        XCTAssertEqual(delivered[2].event.playbackState, "q")
        XCTAssertEqual(delivered[2].event.keys?["pod"] as? String, "mid-1")
    }

    func testTheQuitReachesANamespaceFilteredDestinationOnlyWhenTheFilterListsLens() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads",
                destinations: [
                    LensDestination(
                        url: "https://ads-only.test",
                        filter: LensDestinationFilter(namespaces: ["ads"])),
                    LensDestination(
                        url: "https://ads-and-lens.test",
                        filter: LensDestinationFilter(namespaces: ["ads", "lens"])),
                ],
                heartbeatMs: 0
            )
        )
        lens.startSession()
        lens.emit(LensEventType.adStart)
        lens.endSession()
        func types(_ url: String) -> [String] {
            delivered.filter { $0.destination.url == url }.map(\.event.type)
        }
        XCTAssertEqual(types("https://ads-only.test"), ["as"])
        XCTAssertEqual(types("https://ads-and-lens.test"), ["as", "ps"])
    }

    func testTheNamespaceNeverFlipsSoAFilteredDestinationCannotLoseLiveness() throws {
        captureSink()
        captureTickers()
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads",
                destinations: [
                    LensDestination(
                        url: "https://ads-only.test",
                        filter: LensDestinationFilter(namespaces: ["ads"])),
                    LensDestination(
                        url: "https://lens-filtered.test",
                        filter: LensDestinationFilter(namespaces: ["lens"])),
                    LensDestination(url: "https://adops.test", format: .json),
                ]
            )
        )
        lens.startSession()
        delivered.removeAll()
        running[0].tick()  // plain
        lens.setHeartbeatPayload(LensPayload(custom: ["pod": "mid-1"]))
        running[0].tick()  // contributed
        lens.setHeartbeatPayload(nil)
        running[0].tick()  // plain again
        XCTAssertEqual(
            delivered.map(\.destination.url),
            ["https://ads-only.test", "https://ads-only.test", "https://ads-only.test"]
        )
    }

    // MARK: duplicate copy detection

    func testRegistersItselfUnderTheWellKnownKeyWithoutViolation() {
        let key = "com.dolby.optiview.lens"
        let previous = getenv(key).map { String(cString: $0) }
        defer { restore(key, to: previous) }
        unsetenv(key)

        var warnings: [String] = []
        let defaultWarning = Lens.duplicateCopyWarning
        Lens.duplicateCopyWarning = { warnings.append($0) }
        defer { Lens.duplicateCopyWarning = defaultWarning }

        Lens.detectDuplicateCopy()
        Lens.detectDuplicateCopy()  // the same copy again is not a duplicate
        XCTAssertNotNil(getenv(key))
        XCTAssertEqual(warnings, [])
    }

    func testWarnsWhenAnotherCopyAlreadyRegistered() {
        let key = "com.dolby.optiview.lens"
        let previous = getenv(key).map { String(cString: $0) }
        defer { restore(key, to: previous) }
        setenv(key, "another-copy", 1)

        var warnings: [String] = []
        let defaultWarning = Lens.duplicateCopyWarning
        Lens.duplicateCopyWarning = { warnings.append($0) }
        defer { Lens.duplicateCopyWarning = defaultWarning }

        Lens.detectDuplicateCopy()
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("another copy of the Lens SDK"))
        XCTAssertTrue(warnings[0].contains("another-copy"))
    }

    private func restore(_ key: String, to value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }

    // MARK: dispose

    func testEndsTheSessionAndMakesTheHandleInert() throws {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(namespace: "ads", destinations: [ingest], heartbeatMs: 0))
        lens.startSession()
        lens.dispose()
        XCTAssertNil(lens.session)
        lens.startSession()
        lens.emit(.adStart)
        XCTAssertNil(lens.session)
        // Disposing with a live session quits it; nothing follows.
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].event.type, "ps")
        XCTAssertEqual(delivered[0].event.namespace, "lens")
        XCTAssertEqual(delivered[0].event.playbackState, "q")
    }

    func testAJoinDisposeJoinCycleEmitsOneHeartbeatPerTickSnAdvancingByOne() throws {
        captureTickers()
        var posts: [String] = []
        TransportRuntime.postOverride = { _, body, _ in posts.append(body) }
        defer {
            TransportRuntime.postOverride = { _, _, _ in }
            TransportRuntime.resetSnRegistryForTesting()
        }

        let first = try Lens.join(LensJoinOptions(namespace: "ads"))
        first.startSession(LensStartSessionOptions(sessionId: "sid-teardown"))
        try XCTUnwrap(running.first).tick()
        try XCTUnwrap(running.first).tick()
        let stale = try XCTUnwrap(running.first)
        first.dispose()
        XCTAssertEqual(running.count, 0)
        stale.tick()  // a leaked subscriber would post here

        let second = try Lens.join(LensJoinOptions(namespace: "ads"))
        second.startSession(LensStartSessionOptions(sessionId: "sid-teardown"))
        try XCTUnwrap(running.first).tick()
        second.dispose()

        let sns = posts.map(Self.sn)
        // Three heartbeats then the quit before dispose, none after, two
        // heartbeats and the quit from the second join — a doubled sn step
        // is the signature of two live subscribers.
        XCTAssertEqual(sns, [1, 2, 3, 4, 5, 6, 7])
    }

    // MARK: session ownership

    func testTwoHandlesOnOnePlayerShareTheMintedSidTheSecondSignalJoins() throws {
        captureSink()
        let player = NSObject()
        let ads = try Lens.join(
            LensJoinOptions(
                namespace: "ads", destinations: [ingest], heartbeatMs: 0, player: player))
        let live = try Lens.join(
            LensJoinOptions(
                namespace: "live", destinations: [ingest], heartbeatMs: 0, player: player))
        let minted = ads.startSession()
        let joined = live.startSession()
        XCTAssertEqual(minted.sessionId, joined.sessionId)
        ads.emit(.adStart)
        live.emitCustom("fallback")
        XCTAssertEqual(
            delivered.map { $0.event.session.sessionId },
            [minted.sessionId, minted.sessionId]
        )
    }

    func testEndSessionFromANonMintingHandleWarnsAndIsANoOp() throws {
        captureSink()
        let player = NSObject()
        let ads = try Lens.join(
            LensJoinOptions(
                namespace: "ads", destinations: [ingest], heartbeatMs: 0, player: player))
        let live = try Lens.join(
            LensJoinOptions(
                namespace: "live", destinations: [ingest], heartbeatMs: 0, player: player))
        ads.startSession()
        live.startSession()

        var warnings: [String] = []
        let defaultWarn = Lens.warn
        Lens.warn = { warnings.append($0) }
        defer { Lens.warn = defaultWarn }
        live.endSession()
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("endSession() ignored"))
        XCTAssertNotNil(live.session)
        XCTAssertEqual(delivered.count, 0)

        ads.endSession()
        XCTAssertNil(ads.session)
        XCTAssertNil(live.session)
    }

    func testEndingTheSharedSessionEmitsOneQuitCarryingBothHandlesSnapshots() throws {
        captureSink()
        let player = NSObject()
        let ads = try Lens.join(
            LensJoinOptions(
                namespace: "ads", destinations: [ingest], heartbeatMs: 0, player: player))
        let live = try Lens.join(
            LensJoinOptions(
                namespace: "live", destinations: [ingest], heartbeatMs: 0, player: player))
        ads.startSession()
        live.startSession()
        ads.setHeartbeatPayload(LensPayload(custom: ["pod": "mid-1"]))
        live.setHeartbeatPayload(LensPayload(custom: ["endpoint": 2]))
        ads.endSession()
        XCTAssertEqual(delivered.count, 1)
        let event = delivered[0].event
        XCTAssertEqual(event.type, "ps")
        XCTAssertEqual(event.namespace, "lens")
        XCTAssertEqual(event.playbackState, "q")
        XCTAssertEqual(event.keys?.count, 2)
        XCTAssertEqual(event.keys?["pod"] as? String, "mid-1")
        XCTAssertEqual((event.keys?["endpoint"] as? NSNumber)?.intValue, 2)
    }

    func testDisposingANonLastHandleKeepsTheSessionTheLastOneQuitsItOnce() throws {
        captureSink()
        let player = NSObject()
        let ads = try Lens.join(
            LensJoinOptions(
                namespace: "ads", destinations: [ingest], heartbeatMs: 0, player: player))
        let live = try Lens.join(
            LensJoinOptions(
                namespace: "live", destinations: [ingest], heartbeatMs: 0, player: player))
        ads.startSession()
        live.startSession()
        ads.dispose()
        XCTAssertNotNil(live.session)
        XCTAssertEqual(delivered.count, 0)
        live.dispose()
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].event.type, "ps")
        XCTAssertEqual(delivered[0].event.playbackState, "q")
    }

    func testAfterAnEndTheNextBoundarySignalFromAnyHandleMintsFresh() throws {
        captureSink()
        let player = NSObject()
        let ads = try Lens.join(
            LensJoinOptions(
                namespace: "ads", destinations: [ingest], heartbeatMs: 0, player: player))
        let live = try Lens.join(
            LensJoinOptions(
                namespace: "live", destinations: [ingest], heartbeatMs: 0, player: player))
        let first = ads.startSession()
        ads.endSession()
        let second = live.startSession()
        XCTAssertNotEqual(first.sessionId, second.sessionId)
        // Ownership moved with the mint: now only live's endSession ends it.
        live.endSession()
        XCTAssertNil(live.session)
    }

    // MARK: source changes

    func testAContinuedSessionKeepsTheSidAndEmitsCAndHOnlyWhenTheIdentityActuallyChanged() throws {
        captureSink()
        let player = NSObject()
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "live", destinations: [ingest], heartbeatMs: 0, player: player))
        let session = lens.startSession(LensStartSessionOptions(contentId: "movie-1"))

        // Same content id, first hostname sighting — nothing changed yet.
        lens.reportSourceChange(
            LensSourceChange(newSession: false, contentId: "movie-1", hostname: "a.example.com"))
        XCTAssertEqual(delivered.count, 0)

        lens.reportSourceChange(
            LensSourceChange(newSession: false, contentId: "movie-2", hostname: "b.example.com"))
        XCTAssertEqual(delivered.map { $0.event.type }, ["c", "h"])
        XCTAssertEqual(delivered[0].event.namespace, "lens")
        XCTAssertEqual(delivered[0].event.contentId, "movie-2")
        XCTAssertEqual(delivered[0].event.session.sessionId, session.sessionId)
        XCTAssertEqual(delivered[1].event.namespace, "lens")
        XCTAssertEqual(delivered[1].event.hostname, "b.example.com")

        lens.emitCustom("fallback")
        XCTAssertEqual(delivered[2].event.session.sessionId, session.sessionId)
        XCTAssertEqual(delivered[2].event.contentId, "movie-2")
    }

    func testANewSessionRotatesTheSidQuittingTheReplacedSessionTheMinterKeepsOwnership() throws {
        captureSink()
        let player = NSObject()
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "live", destinations: [ingest], heartbeatMs: 0, player: player))
        let first = lens.startSession(LensStartSessionOptions(contentId: "movie-1"))
        lens.reportSourceChange(LensSourceChange(newSession: true, contentId: "movie-2"))
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].event.type, "ps")
        XCTAssertEqual(delivered[0].event.namespace, "lens")
        XCTAssertEqual(delivered[0].event.playbackState, "q")
        XCTAssertEqual(delivered[0].event.session.sessionId, first.sessionId)
        let rolled = try XCTUnwrap(lens.session)
        XCTAssertNotEqual(first.sessionId, rolled.sessionId)
        lens.emitCustom("fallback")
        XCTAssertEqual(delivered[1].event.session.sessionId, rolled.sessionId)
        XCTAssertEqual(delivered[1].event.contentId, "movie-2")
        lens.endSession()
        XCTAssertNil(lens.session)
    }

    func testANonMinterNewSessionReportLeavesOwnershipWithTheMinter() throws {
        captureSink()
        let player = NSObject()
        let ads = try Lens.join(
            LensJoinOptions(
                namespace: "ads", destinations: [ingest], heartbeatMs: 0, player: player))
        let live = try Lens.join(
            LensJoinOptions(
                namespace: "live", destinations: [ingest], heartbeatMs: 0, player: player))
        let first = ads.startSession(LensStartSessionOptions(contentId: "movie-1"))
        live.startSession()
        live.reportSourceChange(LensSourceChange(newSession: true, contentId: "movie-2"))
        let rolled = try XCTUnwrap(ads.session)
        XCTAssertNotEqual(first.sessionId, rolled.sessionId)
        live.endSession()
        XCTAssertNotNil(ads.session)
        ads.endSession()
        XCTAssertNil(ads.session)
        XCTAssertNil(live.session)
    }

    func testARepeatBoundarySignalQuitsTheReplacedSessionBeforeMintingTheNext() throws {
        captureSink()
        let player = NSObject()
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "live", destinations: [ingest], heartbeatMs: 0, player: player))
        let first = lens.startSession(LensStartSessionOptions(contentId: "movie-1"))
        let second = lens.startSession(LensStartSessionOptions(contentId: "movie-2"))
        XCTAssertNotEqual(first.sessionId, second.sessionId)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].event.type, "ps")
        XCTAssertEqual(delivered[0].event.namespace, "lens")
        XCTAssertEqual(delivered[0].event.playbackState, "q")
        XCTAssertEqual(delivered[0].event.session.sessionId, first.sessionId)
    }

    func testANonMinterContinuedSessionReportRidesTheMinterAsALensReportLikeTheQuit() throws {
        captureSink()
        let player = NSObject()
        let adsIngest = LensDestination(url: "https://example.test/ads")
        let ads = try Lens.join(
            LensJoinOptions(
                namespace: "ads", destinations: [adsIngest], heartbeatMs: 0, player: player))
        let live = try Lens.join(
            LensJoinOptions(
                namespace: "live", destinations: [ingest], heartbeatMs: 0, player: player))
        let session = ads.startSession(LensStartSessionOptions(contentId: "movie-1"))
        live.startSession()
        live.reportSourceChange(LensSourceChange(newSession: false, contentId: "movie-2"))
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].destination.url, adsIngest.url)
        XCTAssertEqual(delivered[0].event.type, "c")
        XCTAssertEqual(delivered[0].event.namespace, "lens")
        XCTAssertEqual(delivered[0].event.contentId, "movie-2")
        XCTAssertEqual(delivered[0].event.session.sessionId, session.sessionId)
        XCTAssertEqual(try XCTUnwrap(ads.session).sessionId, session.sessionId)
    }

    func testAContinuedSessionReportCarriesTheSessionCidNotAnOpenAdSwapAndNeedsAConsentingHandle()
        throws
    {
        captureSink()
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads", destinations: [ingest], heartbeatMs: 0, player: NSObject()))
        lens.startSession(LensStartSessionOptions(contentId: "movie-1"))
        lens.emit(.adStart, payload: LensAdPayload(contentId: "ad-1"))
        lens.reportSourceChange(LensSourceChange(newSession: false, contentId: "movie-2"))
        XCTAssertEqual(delivered[1].event.type, "c")
        XCTAssertEqual(delivered[1].event.contentId, "movie-2")
        lens.setConsent(.denied)
        lens.reportSourceChange(LensSourceChange(newSession: false, contentId: "movie-3"))
        XCTAssertEqual(delivered.count, 2)
    }

    func testRejectsHostileInputsLoudlyBadHostname() throws {
        let violations = captureViolations()
        defer { Lens.usageViolation = { preconditionFailure($0) } }
        let lens = try Lens.join(
            LensJoinOptions(namespace: "live", heartbeatMs: 0, player: NSObject()))
        lens.startSession()
        for hostname in ["", String(repeating: "x", count: 129), "héte.example"] {
            lens.reportSourceChange(LensSourceChange(newSession: false, hostname: hostname))
        }
        XCTAssertEqual(violations().count, 3)
    }

    private static func sn(_ body: String) -> Int? {
        guard let range = body.range(of: #"(^|,)sn=(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return Int(body[range].drop { !$0.isNumber })
    }
}
