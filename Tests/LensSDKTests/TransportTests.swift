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

    nonisolated(unsafe) static var captured: [Captured] = []
    nonisolated(unsafe) static var failFirst = 0
    private static let stateLock = NSLock()

    static func reset() {
        stateLock.lock()
        captured = []
        failFirst = 0
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
        let status = Self.failFirst > 0 ? 500 : 200
        if Self.failFirst > 0 { Self.failFirst -= 1 }
        Self.stateLock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
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
    }

    override func tearDown() {
        TransportRuntime.ingestOverride = nil
        TransportRuntime.postOverride = nil
        TransportRuntime.resetSnRegistryForTesting()
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
                    session: LensSession(sessionId: sid)
                )
                return Encoding.toReport(event, sn)
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

    // MARK: delivery behavior

    func testUsesTheDevelopmentBuiltInEndpointWhenConfigured() throws {
        var postedUrls: [String] = []
        TransportRuntime.ingestOverride = nil
        TransportRuntime.postOverride = { url, _, _ in postedUrls.append(url) }
        let devUrl = "https://dev-ingest.test/events"
        try Lens.useDevelopmentBackend(url: devUrl)
        let lens = try Lens.join(LensJoinOptions(namespace: "ads"))
        lens.startSession()
        lens.emit(.adStart)
        lens.endSession()

        XCTAssertEqual(postedUrls, [devUrl])
    }

    func testDisabledBackendProducesNoBuiltInPost() throws {
        var postedUrls: [String] = []
        TransportRuntime.ingestOverride = nil
        TransportRuntime.postOverride = { url, _, _ in postedUrls.append(url) }
        try Lens.configure(LensConfigureOptions(backend: .disabled))
        let lens = try Lens.join(LensJoinOptions(namespace: "ads"))
        lens.startSession()
        lens.emit(.adStart)
        lens.endSession()

        XCTAssertTrue(postedUrls.isEmpty)
    }

    func testDeliversToTheBuiltInIngestWithThePrefixOnTheWire() throws {
        let lens = try Lens.join(LensJoinOptions(namespace: "ads"))
        lens.startSession()
        lens.emit(.adStart, payload: LensPayload(custom: ["ad": "ad-1"]))
        lens.endSession()

        let requests = waitForRequests(1, path: "/ingest")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].contentType, "application/cmcd")
        XCTAssertTrue(requests[0].body.contains("com.dolby.optiview-ad=\"ad-1\""))
        XCTAssertTrue(requests[0].body.contains("com.dolby.optiview-ns=\"ads\""))
        XCTAssertTrue(requests[0].body.contains("e=as"))
    }

    func testJsonDestinationsNeverSeeThePrefix() throws {
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads",
                destinations: [LensDestination(url: "http://mock.lens/adops", format: .json)]
            ))
        lens.startSession()
        lens.emitCustom("adBreakAdded", payload: LensPayload(custom: ["count": 2]))
        lens.endSession()

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

    func testNumbersReportsPerDestinationAndRestartsSnWhenTheSessionRolls() throws {
        let lens = try Lens.join(LensJoinOptions(namespace: "ads"))
        lens.startSession()
        lens.emit(.adStart)
        lens.emit(.adEnd)
        lens.startSession()
        lens.emit(.adStart)
        lens.endSession()

        let requests = waitForRequests(3, path: "/ingest")
        let bodies = requests.map(\.body).joined(separator: "\n")
        let sns = bodies.split(separator: "\n").compactMap { line -> Int? in
            guard let range = line.range(of: "sn=") else { return nil }
            return Int(line[range.upperBound...].prefix(while: { $0.isNumber }))
        }
        XCTAssertEqual(sns, [1, 2, 1])
    }

    func testRetriesAFailedPostOnce() throws {
        ReceiverProtocol.failFirst = 1
        let lens = try Lens.join(LensJoinOptions(namespace: "ads"))
        lens.startSession()
        lens.emit(.adStart)
        lens.endSession()

        XCTAssertEqual(waitForRequests(2, path: "/ingest").count, 2)
    }
}
