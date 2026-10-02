import XCTest

@testable import LensSDK

#if canImport(CoreFoundation)
    import CoreFoundation
#endif
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// URL-loading-layer mock receiver: captures every POST the transport makes.
final class ReceiverProtocol: URLProtocol {
    struct Captured {
        let path: String
        let contentType: String
        let body: String
    }

    struct Scripted {
        let status: Int
        var headers: [String: String] = [:]
    }

    nonisolated(unsafe) static var captured: [Captured] = []
    nonisolated(unsafe) static var failFirst = 0

    /// Responses per path, in arrival order; exhausted, the receiver settles on 204.
    nonisolated(unsafe) static var script: [String: [Scripted]] = [:]
    private static let stateLock = NSLock()

    static func reset() {
        stateLock.lock()
        captured = []
        failFirst = 0
        script = [:]
        stateLock.unlock()
    }

    static func snapshot() -> [Captured] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mock.lens"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.readBody(of: request)
        Self.stateLock.lock()
        Self.captured.append(
            Captured(
                path: request.url?.path ?? "/",
                contentType: request.value(forHTTPHeaderField: "Content-Type") ?? "",
                body: body
            ))
        let path = request.url?.path ?? "/"
        // The real ingest answers 204 with no body — the happy path tests
        // must accept exactly that.
        var next = ReceiverProtocol.Scripted(status: 204)
        if Self.failFirst > 0 {
            Self.failFirst -= 1
            next = ReceiverProtocol.Scripted(status: 500)
        } else if var scripted = Self.script[path], !scripted.isEmpty {
            next = scripted.removeFirst()
            Self.script[path] = scripted
        }
        Self.stateLock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: next.status, httpVersion: "HTTP/1.1",
            headerFields: next.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readBody(of request: URLRequest) -> String {
        if let data = request.httpBody { return String(data: data, encoding: .utf8) ?? "" }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

final class TransportTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(ReceiverProtocol.self)
        ReceiverProtocol.reset()
        TransportRuntime.ingestOverride = "http://mock.lens/ingest"
        TransportRuntime.backoffBaseMs = 20
    }

    override func tearDown() {
        // Let posts still in flight (a session-end quit report, a scheduled
        // retry) land before the next test resets the captured requests.
        let idleDeadline = Date().addingTimeInterval(1)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while TransportRuntime.inFlightCount > 0 && Date() < idleDeadline
        TransportRuntime.ingestOverride = nil
        TransportRuntime.postOverride = nil
        TransportRuntime.resetSnRegistryForTesting()
        TransportRuntime.resetDeliveryPolicyForTesting()
        Lens.resetConfigurationForTesting()
        URLProtocol.unregisterClass(ReceiverProtocol.self)
        super.tearDown()
    }

    private func waitForRequests(_ count: Int, path: String, timeout: TimeInterval = 2)
        -> [ReceiverProtocol.Captured]
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let matching = ReceiverProtocol.snapshot().filter { $0.path == path }
            if matching.count >= count { return matching }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return ReceiverProtocol.snapshot().filter { $0.path == path }
    }

    // MARK: goldens — the cross-platform wire contract

    func testReproducesTheWireGoldensByteIdentically() throws {
        let fixtureUrl = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/transport-wire.json")
        let data = try Data(contentsOf: fixtureUrl)
        let root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let cases = root["cases"] as! [[String: Any]]
        XCTAssertGreaterThan(cases.count, 0)

        for fixture in cases {
            let name = fixture["name"] as! String
            var counters: [String: Int] = [:]
            let environment = FixtureEnvironment.parse(fixture["environment"] as! [String: Any])
            let userId = fixture["userId"] as! String
            let events = fixture["events"] as! [[String: Any]]
            let reports = events.map { raw -> [(String, Any)] in
                let session = raw["session"] as! [String: Any]
                let keys = (raw["keys"] as? [String: Any]).map { parsed -> LensEventKeys in
                    parsed.mapValues(Self.normalizeJsonValue)
                }
                let sid = session["sessionId"] as! String
                let sn = (counters[sid] ?? 0) + 1
                counters[sid] = sn
                let event = LensEvent(
                    type: raw["type"] as! String,
                    customName: raw["customName"] as? String,
                    namespace: raw["namespace"] as! String,
                    keys: keys,
                    timestamp: (raw["timestamp"] as! NSNumber).int64Value,
                    session: LensSession(sessionId: sid),
                    contentId: raw["contentId"] as? String,
                    streamingFormat: raw["streamingFormat"] as? String,
                    streamType: raw["streamType"] as? String,
                    hostname: raw["hostname"] as? String,
                    playbackState: raw["playbackState"] as? String
                )
                return Encoding.toReport(event, sn, environment, userId)
            }
            let format: LensFormat = (fixture["format"] as! String) == "json" ? .json : .cmcd
            let (body, contentType) = Encoding.encodeBody(format, reports)
            let expected = fixture["expected"] as! [String: Any]
            XCTAssertEqual(contentType, expected["contentType"] as! String, name)
            XCTAssertEqual(body, expected["body"] as! String, name)
        }
    }

    /// JSONSerialization gives NSNumber for both booleans and numbers — split them apart.
    private static func normalizeJsonValue(_ value: Any) -> Any {
        if let sentinel = value as? [String: Any], let name = sentinel["$number"] as? String {
            switch name {
            case "NaN": return Double.nan
            case "Infinity": return Double.infinity
            case "-Infinity": return -Double.infinity
            default: break
            }
        }
        guard let number = value as? NSNumber else { return value }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if number.doubleValue.truncatingRemainder(dividingBy: 1) == 0 { return number.intValue }
        return number.doubleValue
    }

    func testWholeDoublesRenderAsIntegersInBothFormats() {
        let report: [(String, Any)] = [
            ("e", "as"), ("ts", Int64(1)), ("sid", "s"), ("sn", 1), ("v", 2), ("ns", "ads"),
            ("weight", 2.0), ("ratio", 2.5),
        ]
        let json = Encoding.encodeBody(.json, [report]).body
        XCTAssertTrue(json.contains("\"weight\":2,"))
        XCTAssertTrue(json.contains("\"ratio\":2.5"))
        let cmcd = Encoding.encodeBody(.cmcd, [report]).body
        XCTAssertTrue(cmcd.contains("com.dolby.optiview-weight=\"2\""))
        XCTAssertTrue(cmcd.contains("com.dolby.optiview-ratio=\"2.5\""))
    }

    func testNonFiniteNumbersAreAbsentFromBothFormats() {
        let report = Encoding.toReport(
            LensEvent(
                type: "as", customName: nil, namespace: "ads",
                keys: [
                    "doubleNan": Double.nan, "doubleInfinity": Double.infinity,
                    "floatNan": Float.nan, "floatInfinity": Float.infinity, "good": 0.0,
                    "numberNan": NSNumber(value: Double.nan), "cgFloatNan": CGFloat.nan,
                    "bool": true,
                ],
                timestamp: 1, session: LensSession(sessionId: "s")
            ),
            1, LensEnvironment(p: "ios"), "user"
        )
        let json = Encoding.encodeBody(.json, [report]).body
        XCTAssertTrue(json.contains("\"good\":0"))
        XCTAssertFalse(json.contains("doubleNan"))
        XCTAssertFalse(json.contains("doubleInfinity"))
        XCTAssertFalse(json.contains("floatNan"))
        XCTAssertFalse(json.contains("floatInfinity"))
        XCTAssertFalse(json.contains("numberNan"))
        XCTAssertFalse(json.contains("cgFloatNan"))
        XCTAssertTrue(json.contains("\"bool\":true"))
        let cmcd = Encoding.encodeBody(.cmcd, [report]).body
        XCTAssertTrue(cmcd.contains("com.dolby.optiview-good=\"0\""))
        XCTAssertTrue(cmcd.contains("com.dolby.optiview-bool=true"))
        XCTAssertFalse(cmcd.contains("doubleNan"))
        XCTAssertFalse(cmcd.contains("doubleInfinity"))
        XCTAssertFalse(cmcd.contains("floatNan"))
        XCTAssertFalse(cmcd.contains("floatInfinity"))
        XCTAssertFalse(cmcd.contains("numberNan"))
        XCTAssertFalse(cmcd.contains("cgFloatNan"))
    }

    func testExplicitCustomTokensAreBareInCmcdAndStringsInJson() {
        let report: [(String, Any)] = [
            ("e", "ae"), ("ts", Int64(1)), ("sid", "s"), ("sn", 1), ("v", 2), ("ns", "ads"),
            ("ader", LensToken(value: "c")),
        ]
        let json = Encoding.encodeBody(.json, [report]).body
        XCTAssertTrue(json.contains("\"ader\":\"c\""))
        XCTAssertFalse(json.contains("\"ader\":{\"value\":\"c\"}"))
        let cmcd = Encoding.encodeBody(.cmcd, [report]).body
        XCTAssertTrue(cmcd.contains("com.dolby.optiview-ader=c"))
        XCTAssertFalse(cmcd.contains("com.dolby.optiview-ader=\"c\""))
    }

    // MARK: delivery behavior

    func testUsesTheDevelopmentBuiltInEndpointWhenConfigured() throws {
        var postedUrls: [String] = []
        TransportRuntime.ingestOverride = nil
        TransportRuntime.postOverride = { url, _, _ in postedUrls.append(url) }
        let devUrl = "https://dev-ingest.test/events"
        try Lens.useDevelopmentBackend(url: devUrl)
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart)

        XCTAssertEqual(postedUrls, [devUrl])
    }

    func testDisabledBackendProducesNoBuiltInPost() throws {
        var postedUrls: [String] = []
        TransportRuntime.ingestOverride = nil
        TransportRuntime.postOverride = { url, _, _ in postedUrls.append(url) }
        try Lens.configure(LensConfigureOptions(backend: .disabled))
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads", heartbeatMs: 0,
                batch: LensBatch(maxEvents: 10)))
        lens.startSession()
        lens.emit(.adStart)

        XCTAssertTrue(postedUrls.isEmpty)
    }

    func testDeliversToTheBuiltInIngestWithThePrefixOnTheWire() throws {
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart, payload: LensAdPayload(custom: ["ad": "ad-1"]))

        let requests = waitForRequests(1, path: "/ingest")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].contentType, "application/cmcd")
        XCTAssertTrue(requests[0].body.contains("com.dolby.optiview-ad=\"ad-1\""))
        XCTAssertTrue(requests[0].body.contains("com.dolby.optiview-ns=\"ads\""))
        XCTAssertTrue(requests[0].body.contains("e=as"))
    }

    func testTruncatesOverlongCustomStringsOnTheCmcdWireInDefaultMode() throws {
        let value = String(repeating: "x", count: 65)
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart, payload: LensAdPayload(custom: ["ad": value]))

        let requests = waitForRequests(1, path: "/ingest")
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(
            requests[0].body.contains(
                "com.dolby.optiview-ad=\"\(String(repeating: "x", count: 64))\""))
        XCTAssertFalse(requests[0].body.contains("com.dolby.optiview-ad=\"\(value)\""))
    }

    func testWarnsOncePerSessionAndKeyWhenTruncatingCustomStrings() throws {
        let originalWarn = Lens.warn
        var warnings: [String] = []
        Lens.warn = { warnings.append($0) }
        defer { Lens.warn = originalWarn }

        let value = String(repeating: "x", count: 65)
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart, payload: LensAdPayload(custom: ["ad": value]))
        lens.emit(.adEnd, payload: LensAdPayload(custom: ["ad": value, "bid": value]))
        lens.startSession()
        lens.emit(.adStart, payload: LensAdPayload(custom: ["ad": value]))

        // The roll's quit rides along; the truncation story is about the emits.
        let requests = waitForRequests(4, path: "/ingest").filter { !$0.body.contains("e=ps") }
        let adWarning =
            "Lens: custom value for 'ad' exceeds 64 UTF-16 units and is truncated on the CMCD wire"
        XCTAssertEqual(
            warnings,
            [
                adWarning,
                "Lens: custom value for 'bid' exceeds 64 UTF-16 units and is truncated on the CMCD wire",
                adWarning,
            ])
        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(
            requests.allSatisfy {
                $0.body.contains(
                    "com.dolby.optiview-ad=\"\(String(repeating: "x", count: 64))\"")
            })
        XCTAssertTrue(
            requests.allSatisfy {
                !$0.body.contains("com.dolby.optiview-ad=\"\(value)\"")
            })
    }

    func testCountsUtf16UnitsWhenTruncatingAstralCustomStringsOnTheCmcdWire() throws {
        let originalWarn = Lens.warn
        var warnings: [String] = []
        Lens.warn = { warnings.append($0) }
        defer { Lens.warn = originalWarn }

        let value = String(repeating: "𝄞", count: 33)
        XCTAssertEqual(value.utf16.count, 66)
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart, payload: LensAdPayload(custom: ["ad": value]))

        let requests = waitForRequests(1, path: "/ingest")
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(
            requests[0].body.contains(
                "com.dolby.optiview-ad=\"\(String(repeating: "𝄞", count: 32))\""))
        XCTAssertFalse(requests[0].body.contains("com.dolby.optiview-ad=\"\(value)\""))
        XCTAssertEqual(
            warnings,
            [
                "Lens: custom value for 'ad' exceeds 64 UTF-16 units and is truncated on the CMCD wire"
            ])
    }

    func testJsonDestinationsNeverSeeThePrefix() throws {
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads",
                destinations: [LensDestination(url: "http://mock.lens/adops", format: .json)]
            ))
        lens.startSession()
        lens.emitCustom("adBreakAdded", payload: LensPayload(custom: ["count": 2]))

        let requests = waitForRequests(1, path: "/adops")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].contentType, "application/json")
        XCTAssertFalse(requests[0].body.contains("com.dolby.optiview-"))
        XCTAssertTrue(requests[0].body.contains("\"cen\":\"adBreakAdded\""))
        XCTAssertTrue(requests[0].body.contains("\"count\":2"))
    }

    func testBatchesPerDestinationHintsAndFlushesOnSessionEnd() throws {
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads",
                destinations: [
                    LensDestination(
                        url: "http://mock.lens/batched", format: .json,
                        batch: LensBatch(maxEvents: 3))
                ]
            ))
        lens.startSession()
        lens.emit(.adBreakStart)
        lens.emit(.adStart)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/batched" }.count, 0)

        lens.emit(.adEnd)
        XCTAssertEqual(waitForRequests(1, path: "/batched").count, 1)

        lens.emit(.adBreakEnd)
        lens.endSession()
        XCTAssertEqual(waitForRequests(2, path: "/batched").count, 2)
    }

    func testBatchesBuiltInIngestReportsAtMaxEvents() throws {
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads", heartbeatMs: 0,
                batch: LensBatch(maxEvents: 3)))
        lens.startSession()
        lens.emit(.adStart)
        lens.emit(.adEnd)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/ingest" }.count, 0)

        lens.emit(.adSkip)
        let requests = waitForRequests(1, path: "/ingest")
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/ingest" }.count, 1)
        XCTAssertEqual(requests[0].body.split(separator: "\n").count, 3)
    }

    func testFlushesBuiltInIngestAfterMaxDelayMs() throws {
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads", heartbeatMs: 0,
                batch: LensBatch(maxEvents: 10, maxDelayMs: 200)))
        lens.startSession()
        lens.emit(.adStart)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/ingest" }.count, 0)

        let requests = waitForRequests(1, path: "/ingest")
        XCTAssertTrue(requests[0].body.contains("e=as"))
    }

    func testFlushesPendingBuiltInIngestReportsOnEndSession() throws {
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads", heartbeatMs: 0,
                batch: LensBatch(maxEvents: 10)))
        lens.startSession()
        lens.emit(.adStart)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/ingest" }.count, 0)

        lens.endSession()
        let requests = waitForRequests(1, path: "/ingest")
        XCTAssertEqual(requests[0].body.split(separator: "\n").count, 2)
        XCTAssertTrue(requests[0].body.contains("e=as"))
        XCTAssertTrue(requests[0].body.contains("e=ps"))
    }

    func testFlushesPendingBuiltInIngestBeforeARepeatedStartRollsTheSession() throws {
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads", heartbeatMs: 0,
                batch: LensBatch(maxEvents: 10)))
        lens.startSession()
        let firstSessionId = try XCTUnwrap(lens.session?.sessionId)
        lens.emit(.adStart)

        lens.startSession()
        let firstRequests = waitForRequests(1, path: "/ingest")
        XCTAssertEqual(firstRequests.count, 1)
        func fields(_ key: String, _ body: String) -> [String] {
            body.split(separator: "\n").compactMap { line in
                guard let range = line.range(of: "\(key)=") else { return nil }
                return String(line[range.upperBound...].prefix(while: { $0 != "," }))
            }
        }
        XCTAssertEqual(fields("e", firstRequests[0].body), ["as", "ps"])
        XCTAssertEqual(
            fields("sid", firstRequests[0].body),
            ["\"\(firstSessionId)\"", "\"\(firstSessionId)\""])

        let secondSessionId = try XCTUnwrap(lens.session?.sessionId)
        XCTAssertNotEqual(firstSessionId, secondSessionId)
        lens.emit(.adEnd)
        lens.endSession()

        let requests = waitForRequests(2, path: "/ingest")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(fields("e", requests[1].body), ["ae", "ps"])
        XCTAssertEqual(
            fields("sid", requests[1].body),
            ["\"\(secondSessionId)\"", "\"\(secondSessionId)\""])
    }

    func testOpeningHeartbeatWaitsInTheBuiltInIngestBatch() throws {
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads", heartbeatMs: 1_000,
                batch: LensBatch(maxEvents: 10)))
        lens.startSession()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/ingest" }.count, 0)

        lens.flush()
        let requests = waitForRequests(1, path: "/ingest")
        XCTAssertTrue(requests[0].body.contains("e=t"))
    }

    func testNumbersReportsPerDestinationAndRestartsSnWhenTheSessionRolls() throws {
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart)
        lens.emit(.adEnd)
        lens.startSession()
        lens.emit(.adStart)
        lens.endSession()

        // Concurrent posts may arrive in any order — pin sn per (sid, event).
        let requests = waitForRequests(5, path: "/ingest")
        func field(_ key: String, _ body: String) -> String {
            guard let range = body.range(of: "\(key)=") else { return "" }
            return String(
                body[range.upperBound...].prefix(while: { $0 != "," && $0 != "\n" }))
        }
        let posts = requests.map {
            "\(field("sid", $0.body)) \(field("e", $0.body)) sn=\(field("sn", $0.body))"
        }
        let sids = requests.map { field("sid", $0.body) }
        XCTAssertEqual(Set(sids).count, 2)
        let first = sids[0]
        let rolled = sids.first { $0 != first }!
        XCTAssertTrue(posts.contains("\(first) as sn=1"))
        XCTAssertTrue(posts.contains("\(first) ae sn=2"))
        // Each quit report continues its ending session's sequence, never a fresh one.
        XCTAssertTrue(posts.contains("\(first) ps sn=3"))
        XCTAssertTrue(posts.contains("\(rolled) as sn=1"))
        XCTAssertTrue(posts.contains("\(rolled) ps sn=2"))
        XCTAssertTrue(
            requests.filter { $0.body.contains("e=ps") }.allSatisfy {
                $0.body.contains("sta=q")
            })
    }

    func testA204WithNoBodyIsDeliveryNotAFailure() throws {
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart)

        XCTAssertEqual(waitForRequests(1, path: "/ingest").count, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/ingest" }.count, 1)
    }

    func testBacksOffOn429AndRetriesTheSameBodyUntilAccepted() throws {
        ReceiverProtocol.script["/ingest"] = [.init(status: 429), .init(status: 429)]
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart)

        let posts = waitForRequests(3, path: "/ingest")
        XCTAssertEqual(posts.count, 3)
        XCTAssertEqual(Set(posts.map(\.body)).count, 1)
    }

    func testHonorsRetryAfterDeltaSecondsOn429() throws {
        ReceiverProtocol.script["/ingest"] = [.init(status: 429, headers: ["Retry-After": "1"])]
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart)

        XCTAssertEqual(waitForRequests(1, path: "/ingest").count, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        // The header said one second; the shrunken test backoff would have
        // retried well within the settle window.
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/ingest" }.count, 1)
        XCTAssertEqual(waitForRequests(2, path: "/ingest", timeout: 3).count, 2)
    }

    func testGivesUpAfterThreeRetriesOnPersistent5xx() throws {
        ReceiverProtocol.failFirst = 10
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart)

        XCTAssertEqual(waitForRequests(4, path: "/ingest").count, 4)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/ingest" }.count, 4)
        XCTAssertEqual(TransportRuntime.inFlightCount, 0)
    }

    func testDoesNotRetryOther4xx() throws {
        ReceiverProtocol.script["/ingest"] = [.init(status: 400)]
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adStart)

        XCTAssertEqual(waitForRequests(1, path: "/ingest").count, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/ingest" }.count, 1)
    }

    func testCeasesA410TargetWhileOtherDestinationsKeepDelivering() throws {
        ReceiverProtocol.script["/gone"] = [.init(status: 410)]
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads",
                destinations: [LensDestination(url: "http://mock.lens/gone", format: .json)],
                heartbeatMs: 0
            ))
        lens.startSession()
        lens.emit(.adStart)
        XCTAssertEqual(waitForRequests(1, path: "/gone").count, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        lens.emit(.adEnd)

        XCTAssertEqual(waitForRequests(2, path: "/ingest").count, 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        // The 410 answered the first post; the second never went out.
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/gone" }.count, 1)
    }

    func testHoldsEventsDuringCooldownAndDeliversThemInOnePost() throws {
        ReceiverProtocol.script["/ingest"] = [.init(status: 503, headers: ["Retry-After": "1"])]
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adBreakStart)
        XCTAssertEqual(waitForRequests(1, path: "/ingest").count, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        // The target is cooling down — these accumulate instead of posting.
        lens.emit(.adStart)
        lens.emit(.adEnd)
        lens.flush()

        let posts = waitForRequests(3, path: "/ingest")
        let held = posts.filter { $0.body.contains("e=as") }
        XCTAssertEqual(held.count, 1)
        XCTAssertTrue(held[0].body.contains("e=ae"))
    }

    func testIgnoresMalformedRetryAfterAndCapsHugeValues() {
        func parsed(_ header: String?, status: Int = 429) -> Int? {
            var fields: [String: String] = [:]
            if let header { fields["Retry-After"] = header }
            let response = HTTPURLResponse(
                url: URL(string: "http://mock.lens/ingest")!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: fields)!
            return TransportRuntime.retryAfterMs(response, status: status)
        }
        XCTAssertEqual(parsed("2"), 2000)
        XCTAssertEqual(parsed(" 2 ", status: 503), 2000)
        XCTAssertNil(parsed("2", status: 500))  // only 429/503 carry it
        XCTAssertNil(parsed("Fri, 31 Dec 1999 23:59:59 GMT"))
        XCTAssertNil(parsed("-1"))
        XCTAssertNil(parsed("1.5"))
        XCTAssertNil(parsed("soon"))
        XCTAssertEqual(parsed("86400"), 30000)
        XCTAssertNil(parsed(nil))
    }

    func testBoundsACooldownHeldQueueTo128EventsEvictingTheOldest() throws {
        ReceiverProtocol.script["/ingest"] = [.init(status: 503, headers: ["Retry-After": "1"])]
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adBreakStart)
        XCTAssertEqual(waitForRequests(1, path: "/ingest").count, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        lens.emit(.adBreakEnd)  // oldest held — evicted below
        for _ in 0..<128 { lens.emit(.adStart) }
        lens.flush()

        let posts = waitForRequests(2, path: "/ingest")
        let held = posts.first { $0.body.contains("e=as") }!
        XCTAssertEqual(held.body.components(separatedBy: "e=as").count - 1, 128)
        XCTAssertFalse(held.body.contains("e=abe"))
    }

    func testFlushPostsEvenWhileTheTargetIsCoolingDown() throws {
        ReceiverProtocol.script["/ingest"] = [.init(status: 503, headers: ["Retry-After": "30"])]
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.startSession()
        lens.emit(.adBreakStart)
        XCTAssertEqual(waitForRequests(1, path: "/ingest").count, 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        lens.emit(.adStart)
        lens.flush()

        // The 30s cooldown would outlive any lifecycle cliff — flush bypasses it.
        let posts = waitForRequests(2, path: "/ingest")
        XCTAssertEqual(posts.count, 2)
        XCTAssertTrue(posts[1].body.contains("e=as"))
    }

    func testFlushAllPostsEveryLiveHandlesPendingEvents() throws {
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads",
                destinations: [
                    LensDestination(
                        url: "http://mock.lens/batched", format: .json,
                        batch: LensBatch(maxEvents: 10))
                ],
                heartbeatMs: 0
            ))
        lens.startSession()
        lens.emit(.adStart)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(ReceiverProtocol.snapshot().filter { $0.path == "/batched" }.count, 0)

        TransportRuntime.flushAll()
        XCTAssertEqual(waitForRequests(1, path: "/batched").count, 1)
        lens.dispose()
    }

    func testFlushPostsPendingEventsWithoutEndingTheSession() throws {
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads",
                destinations: [
                    LensDestination(
                        url: "http://mock.lens/batched", format: .json,
                        batch: LensBatch(maxEvents: 10))
                ],
                heartbeatMs: 0
            ))
        lens.startSession()
        lens.emit(.adStart)
        lens.flush()

        XCTAssertEqual(waitForRequests(1, path: "/batched").count, 1)
        XCTAssertNotNil(lens.session)
        lens.dispose()
        lens.flush()  // disposed: a no-op, never a crash
    }

    func testDisposeLeavesZeroLiveTransports() throws {
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        XCTAssertGreaterThanOrEqual(TransportRuntime.liveTransportCountForTesting, 1)
        lens.dispose()
        // ARC is deterministic: handles other tests leaked are already gone,
        // so the count really is zero, not merely smaller.
        XCTAssertEqual(TransportRuntime.liveTransportCountForTesting, 0)
    }

    func testDroppedUnanchoredHandleDeallocatesWithALiveSession() throws {
        weak var dropped: AnyObject?
        func makeAndDrop() throws {
            let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
            lens.startSession()
            dropped = lens as AnyObject
        }
        try makeAndDrop()
        XCTAssertNil(dropped)
    }

    // The macOS dev host has no UIKit, so the local `swift test` gate skips
    // these — the simulator CI job is where they run.
    #if canImport(UIKit)
        func testLifecycleObserversFollowTheLiveSet() throws {
            let first = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
            let second = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
            XCTAssertEqual(TransportRuntime.lifecycleObserverCountForTesting, 2)

            first.dispose()
            XCTAssertEqual(TransportRuntime.lifecycleObserverCountForTesting, 2)
            second.dispose()
            XCTAssertEqual(TransportRuntime.lifecycleObserverCountForTesting, 0)

            // The next transport reinstalls the observers.
            let third = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
            XCTAssertEqual(TransportRuntime.lifecycleObserverCountForTesting, 2)
            third.dispose()
        }

        func testBackgroundNotificationFlushesWhileLiveAndRunsNothingAfterTheLastDispose() throws {
            let lens = try Lens.join(
                LensJoinOptions(
                    namespace: "ads",
                    destinations: [
                        LensDestination(
                            url: "http://mock.lens/batched", format: .json,
                            batch: LensBatch(maxEvents: 10))
                    ],
                    heartbeatMs: 0
                ))
            lens.startSession()
            lens.emit(.adStart)

            NotificationCenter.default.post(
                name: UIApplication.didEnterBackgroundNotification, object: nil)
            XCTAssertEqual(waitForRequests(1, path: "/batched").count, 1)

            lens.dispose()
            NotificationCenter.default.post(
                name: UIApplication.didEnterBackgroundNotification, object: nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(
                ReceiverProtocol.snapshot().filter { $0.path == "/batched" }.count, 1)
        }
    #endif
}
