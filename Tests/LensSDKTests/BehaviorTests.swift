import XCTest

@testable import LensSDK

#if canImport(CoreFoundation)
    import CoreFoundation
#endif

/// Replays conformance/fixtures/transport-behavior.json — the cross-platform
/// delivery-behavior contract: queue scoping, sequence numbers, flush
/// boundaries, consent purge. Posts must match the web reference byte for byte.
final class BehaviorTests: XCTestCase {
    private let adEventTypes: [String: LensEventType<LensAdPayload>] = [
        "as": .adStart, "ae": .adEnd, "sk": .adSkip,
    ]
    private let plainEventTypes: [String: LensEventType<LensPayload>] = [
        "abs": .adBreakStart, "abe": .adBreakEnd,
    ]
    private let defaultAppHidden = Lens.appHidden

    override func tearDown() {
        TransportRuntime.postOverride = nil
        EnvironmentRuntime.override = nil
        Lens.nowForTesting = nil
        Lens.sessionIdFactory = { UUID().uuidString.lowercased() }
        UserIdRuntime.resetForTesting()
        Lens.appHidden = defaultAppHidden
        TransportRuntime.resetSnRegistryForTesting()
        Lens.resetConfigurationForTesting()
        super.tearDown()
    }

    private func normalize(_ value: Any) -> Any {
        guard let number = value as? NSNumber else { return value }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if number.doubleValue.truncatingRemainder(dividingBy: 1) == 0 { return number.intValue }
        return number.doubleValue
    }

    private func parseDestinations(_ raw: [[String: Any]]?) -> [LensDestination] {
        (raw ?? []).map { d in
            var batch: LensBatch?
            if let b = d["batch"] as? [String: Any] {
                batch = LensBatch(
                    maxEvents: (b["maxEvents"] as? NSNumber)?.intValue,
                    maxDelayMs: (b["maxDelayMs"] as? NSNumber)?.int64Value
                )
            }
            return LensDestination(
                url: d["url"] as! String,
                format: (d["format"] as? String) == "json" ? .json : .cmcd,
                batch: batch
            )
        }
    }

    private func payload(_ step: [String: Any]) -> LensPayload? {
        guard let custom = step["custom"] as? [String: Any] else { return nil }
        return LensPayload(custom: custom.mapValues(normalize))
    }

    private func adPayload(_ step: [String: Any]) -> LensAdPayload {
        LensAdPayload(
            contentId: step["contentId"] as? String,
            custom: (step["custom"] as? [String: Any])?.mapValues(normalize)
        )
    }

    func testReproducesTheBehaviorGoldensByteIdentically() throws {
        let fixtureUrl = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/fixtures/transport-behavior.json")
        let root =
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureUrl)) as! [String: Any]
        let cases = root["cases"] as! [[String: Any]]
        XCTAssertGreaterThan(cases.count, 0)

        for fixture in cases {
            let name = fixture["name"] as! String
            var posts: [(url: String, contentType: String, body: String)] = []
            TransportRuntime.postOverride = { url, body, contentType in
                posts.append((url, contentType, body))
            }
            TransportRuntime.resetSnRegistryForTesting()
            Lens.resetConfigurationForTesting()
            var handles: [String: LensHandle] = [:]
            var players: [String: FakePlayer] = [:]
            func player(_ step: [String: Any]) -> FakePlayer {
                let name = step["player"] as! String
                if let existing = players[name] { return existing }
                let created = FakePlayer()
                players[name] = created
                return created
            }
            // The app starts in the foreground; `page` steps send it to the
            // background and back, as the web page's visibility does there.
            var appHidden = false
            Lens.appHidden = { appHidden }

            for step in fixture["script"] as! [[String: Any]] {
                let op = step["op"] as! String
                switch op {
                case "clock":
                    let ms = (step["ms"] as! NSNumber).int64Value
                    Lens.nowForTesting = { ms }
                case "env":
                    EnvironmentRuntime.override = FixtureEnvironment.parse(
                        step["environment"] as! [String: Any])
                case "user":
                    UserIdRuntime.override = (step["userId"] as! String)
                case "configure":
                    let backend = (step["backend"] as! String)
                    try Lens.configure(
                        LensConfigureOptions(
                            backend:
                                backend == "disabled" ? .disabled : .production
                        ))
                case "join":
                    handles[step["handle"] as! String] = try Lens.join(
                        LensJoinOptions(
                            namespace: step["namespace"] as! String,
                            destinations: parseDestinations(
                                step["destinations"] as? [[String: Any]]),
                            player: step["player"] == nil ? nil : player(step)
                        ))
                case "sids":
                    var queue = step["values"] as! [String]
                    Lens.sessionIdFactory = { queue.removeFirst() }
                case "reportSourceChange":
                    handles[step["handle"] as! String]!
                        .reportSourceChange(
                            LensSourceChange(
                                newSession: step["newSession"] as! Bool,
                                contentId: step["contentId"] as? String,
                                hostname: step["hostname"] as? String,
                                streamingFormat: step["streamingFormat"] as? String
                            ))
                case "setHeartbeatPayload":
                    handles[step["handle"] as! String]!
                        .setHeartbeatPayload(payload(step))
                case "startSession":
                    handles[step["handle"] as! String]!
                        .startSession(
                            LensStartSessionOptions(
                                sessionId: step["sessionId"] as? String,
                                contentId: step["contentId"] as? String,
                                streamingFormat: step["streamingFormat"] as? String,
                                streamType: step["streamType"] as? String
                            ))
                case "endSession":
                    handles[step["handle"] as! String]!.endSession()
                case "emit":
                    let handle = handles[step["handle"] as! String]!
                    let type = step["type"] as! String
                    if let ad = adEventTypes[type] {
                        handle.emit(ad, payload: adPayload(step))
                    } else {
                        handle.emit(plainEventTypes[type]!, payload: payload(step))
                    }
                case "emitCustom":
                    handles[step["handle"] as! String]!
                        .emitCustom(step["name"] as! String, payload: payload(step))
                case "setConsent":
                    handles[step["handle"] as! String]!
                        .setConsent((step["consent"] as! String) == "denied" ? .denied : .granted)
                case "dispose":
                    handles[step["handle"] as! String]!.dispose()
                case "playerSnapshot":
                    PlayerFixture.apply(
                        snapshot: step["values"] as! [String: Any], to: &player(step).snapshotValues
                    )
                case "playerChange":
                    let target = player(step)
                    target.change {
                        PlayerFixture.apply(
                            properties: step["properties"] as! [String: Any], to: &$0)
                    }
                case "playerSource":
                    player(step).load(
                        PlayerFixture.source(step["source"]),
                        continuation: step["continuation"] as? Bool ?? false)
                case "playerFact":
                    player(step).fire(PlayerFixture.fact(step["fact"] as! [String: Any]))
                case "page":
                    appHidden = step["hidden"] as! Bool
                    PlayerObserver.appVisibilityChanged(hidden: appHidden)
                default:
                    XCTFail("unknown op \(op) in \(name)")
                }
            }

            let expected = fixture["expected"] as! [[String: Any]]
            XCTAssertEqual(posts.count, expected.count, name)
            for (index, e) in expected.enumerated() where index < posts.count {
                XCTAssertEqual(posts[index].url, e["url"] as! String, name)
                XCTAssertEqual(posts[index].contentType, e["contentType"] as! String, name)
                XCTAssertEqual(posts[index].body, e["body"] as! String, name)
            }
        }
    }
}
