import XCTest

@testable import LensSDK

#if canImport(UIKit)
    import UIKit
#endif

/// Lens observing a player through `LensPlayerAdapter`: sessions, states,
/// keys, sources, app visibility, and the main-queue rule for adapter calls.
/// The same behavior as web's player tests in lens.test.ts.
final class PlayerTests: XCTestCase {
    private var delivered: [LensEvent] = []
    private var warnings: [String] = []
    private var clock: Int64 = 1_000
    private let ingest = LensDestination(url: "https://example.test/ingest")
    private let defaultWarn = Lens.warn
    private let defaultTicker = Lens.ticker
    private let defaultAppHidden = Lens.appHidden

    override func setUp() {
        super.setUp()
        TransportRuntime.postOverride = { _, _, _ in }
        delivered = []
        warnings = []
        clock = 1_000
        Lens.sinkForTesting = { [unowned self] _, event in delivered.append(event) }
        Lens.warn = { [unowned self] in warnings.append($0) }
        Lens.nowForTesting = { [unowned self] in clock }
        // A test host has no app in front: only the adapter's view counts.
        Lens.appHidden = { nil }
    }

    override func tearDown() {
        TransportRuntime.postOverride = nil
        Lens.sinkForTesting = nil
        Lens.warn = defaultWarn
        Lens.ticker = defaultTicker
        Lens.nowForTesting = nil
        Lens.appHidden = defaultAppHidden
        Capabilities.setProbesForTesting(nil)
        Lens.resetConfigurationForTesting()
        super.tearDown()
    }

    // MARK: helpers

    private func join(
        _ player: FakePlayer, namespace: String = "ads", heartbeatMs: Int64 = 0
    ) throws -> LensHandle {
        try Lens.join(
            LensJoinOptions(
                namespace: namespace, destinations: [ingest], heartbeatMs: heartbeatMs,
                player: player))
    }

    private func reports(_ type: String? = nil) -> [LensEvent] {
        delivered.filter { type == nil || $0.type == type }
    }

    private func states() -> [String?] {
        reports("ps").map(\.playbackState)
    }

    private func probe(_ lens: LensHandle) -> LensEvent {
        lens.emitCustom("probe")
        return delivered.last!
    }

    private func status(_ event: LensEvent) -> StatusKeys {
        event.status ?? StatusKeys()
    }

    private func keys(_ pairs: KeyValuePairs<String, StatusValue>) -> StatusKeys {
        var keys = StatusKeys()
        for (key, value) in pairs { keys[key] = value }
        return keys
    }

    private func list(_ values: Double...) -> StatusValue {
        .list(values.map { InnerListItem($0) })
    }

    private func split(_ items: (Double, String)...) -> StatusValue {
        .list(items.map { InnerListItem($0.0, ot: $0.1) })
    }

    private final class Ticker {
        let tick: () -> Void
        var stopped = false
        init(_ tick: @escaping () -> Void) { self.tick = tick }
    }

    private var tickers: [Ticker] = []
    private var running: [Ticker] { tickers.filter { !$0.stopped } }

    private func captureTickers() {
        tickers = []
        Lens.ticker = { [unowned self] _, tick in
            let ticker = Ticker(tick)
            tickers.append(ticker)
            return { ticker.stopped = true }
        }
    }

    /// Lets main-queue work scheduled from other threads run.
    private func drainMainQueue(until done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while !done() && Date() < deadline
    }

    private func onBackground(_ work: @escaping () -> Void) {
        let finished = expectation(description: "background work")
        DispatchQueue.global().async {
            work()
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
    }

    private static let urlA = "https://cdn-a.example.com/movie.m3u8"

    // MARK: session ownership on a player

    func testTwoHandlesOnOneAdapterShareTheSessionItsFirstPlaybackAttemptStarts() throws {
        let player = FakePlayer()
        let ads = try join(player)
        let live = try join(player, namespace: "live")
        XCTAssertEqual(player.subscribeCalls, 1)
        player.load(LensPlayerSource(url: Self.urlA))
        // A source only set is not a playback: no session yet, reports are held.
        XCTAssertNil(ads.session)
        ads.emit(.adStart)
        live.emitCustom("fallback")
        XCTAssertEqual(delivered.count, 0)
        player.fire(.play)
        let sid = try XCTUnwrap(ads.session).sessionId
        XCTAssertEqual(live.session?.sessionId, sid)
        XCTAssertEqual(delivered.map(\.type), ["as", "ce", "ps"])
        XCTAssertEqual(delivered.map(\.session.sessionId), [sid, sid, sid])
    }

    func testTheSessionDoorIsClosedOnAPlayer() throws {
        let player = FakePlayer()
        let lens = try join(player)
        // Between sessions the door hands back a placeholder; `session` tells the truth.
        XCTAssertFalse(lens.startSession().sessionId.isEmpty)
        XCTAssertNil(lens.session)
        player.load(LensPlayerSource(url: Self.urlA, autoplay: true))
        let sid = try XCTUnwrap(lens.session).sessionId
        XCTAssertEqual(lens.startSession().sessionId, sid)
        lens.endSession()
        lens.reportSourceChange(LensSourceChange(newSession: true, contentId: "movie-2"))
        XCTAssertEqual(lens.session?.sessionId, sid)
        XCTAssertEqual(delivered.map(\.playbackState), ["s"])
        XCTAssertTrue(warnings.contains { $0.contains("startSession() ignored") })
        XCTAssertTrue(warnings.contains { $0.contains("endSession() ignored") })
        XCTAssertTrue(warnings.contains { $0.contains("reportSourceChange() ignored") })
    }

    func testTheLastHandleLeavingQuitsAndReleasesTheSubscription() throws {
        let player = FakePlayer()
        let ads = try join(player)
        let live = try join(player, namespace: "live")
        player.load(LensPlayerSource(url: Self.urlA, autoplay: true))
        let first = try XCTUnwrap(live.session).sessionId
        ads.dispose()
        XCTAssertNotNil(live.session)
        XCTAssertEqual(player.listenerCount, 1)
        XCTAssertEqual(delivered.count, 1)
        live.dispose()
        XCTAssertEqual(player.listenerCount, 0)
        XCTAssertEqual(delivered.map(\.type), ["ps", "ps"])
        XCTAssertEqual(delivered.map(\.playbackState), ["s", "q"])

        // The player still has its source: the initial fact brings it.
        let again = try join(player)
        XCTAssertEqual(player.subscribeCalls, 2)
        XCTAssertEqual(player.listenerCount, 1)
        XCTAssertNotEqual(again.session?.sessionId, first)
    }

    func testAHandleJoiningARunningSessionHeartbeatsFromTheMomentItJoins() throws {
        captureTickers()
        let player = FakePlayer()
        _ = try join(player)
        player.load(LensPlayerSource(url: Self.urlA, autoplay: true))
        _ = try join(player, namespace: "live", heartbeatMs: 30_000)
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(delivered.map(\.type), ["ps", "t"])
        XCTAssertEqual(delivered.map(\.namespace), ["lens", "live"])
    }

    func testReportsMadeBeforePlaybackKeepTheirTimeAndGoOutWhenItStartsHeartbeatsWait() throws {
        captureTickers()
        let player = FakePlayer()
        let ads = try join(player, heartbeatMs: 30_000)
        // Before any source, such as a discovery call: it waits for the next session.
        ads.emitCustom("discovered")
        clock = 2_000
        player.load(LensPlayerSource(url: Self.urlA))
        player.change { $0.muted = true }
        player.change { $0.muted = false }
        XCTAssertEqual(running.count, 0)
        XCTAssertEqual(delivered.count, 0)
        clock = 3_000
        player.fire(.play)
        XCTAssertEqual(delivered.map(\.type), ["ce", "um", "ps", "t"])
        XCTAssertEqual(delivered.map(\.timestamp), [1_000, 2_000, 3_000, 3_000])
        XCTAssertEqual(delivered.map(\.playbackState), [nil, nil, "s", "s"])
        XCTAssertEqual(running.count, 1)
        XCTAssertEqual(Set(delivered.map(\.session.sessionId)).count, 1)
    }

    func testReportsMadeUnderASourceGoWithItIfItGoesBeforePlaybackEarlierOnesWaitOn() throws {
        let player = FakePlayer()
        let ads = try join(player)
        ads.emitCustom("discovered")
        player.load(LensPlayerSource(url: Self.urlA))
        ads.emitCustom("for_a")
        player.load(LensPlayerSource(url: "https://cdn-a.example.com/b.m3u8"))
        ads.emitCustom("for_b")
        player.load(nil)
        player.load(LensPlayerSource(url: "https://cdn-a.example.com/c.m3u8", autoplay: true))
        XCTAssertEqual(delivered.map { $0.customName ?? $0.playbackState }, ["discovered", "s"])
    }

    func testTheAppTerminatingBeforePlaybackWasAttemptedSendsNothing() throws {
        let player = FakePlayer()
        let ads = try join(player)
        player.load(LensPlayerSource(url: Self.urlA))
        ads.emitCustom("for_a")
        TransportRuntime.terminationNotifier?()
        player.fire(.play)
        // The end is final; the next play starts afresh, without what was held.
        XCTAssertEqual(delivered.map { $0.customName ?? $0.playbackState }, ["s"])
    }

    func testDeniedConsentAndDisposeDropWhatAHandleHeldTheOtherHandlesKeepTheirs() throws {
        let player = FakePlayer()
        let ads = try join(player)
        let live = try join(player, namespace: "live")
        let other = try join(player, namespace: "other")
        player.load(LensPlayerSource(url: Self.urlA))
        ads.emitCustom("from_ads")
        live.emitCustom("from_live")
        other.emitCustom("from_other")
        ads.setConsent(.denied)
        ads.setConsent(.granted)
        live.dispose()
        player.fire(.play)
        XCTAssertEqual(delivered.map { $0.customName ?? $0.playbackState }, ["from_other", "s"])
    }

    func testLensOwnHeldReportsBelongToThePlayerNotToTheHandleThatHappenedToBeFirst() throws {
        let player = FakePlayer()
        let ads = try join(player)
        let live = try join(player, namespace: "live")
        let other = try join(player, namespace: "other")
        player.load(LensPlayerSource(url: Self.urlA))
        player.change { $0.hasMediaData = true }  // the preload `d`, held for the session
        ads.setConsent(.denied)
        live.dispose()
        player.fire(.play)
        XCTAssertEqual(delivered.map(\.playbackState), ["d", "s"])
        XCTAssertEqual(delivered.map(\.namespace), ["lens", "lens"])
        XCTAssertNotNil(other.session)
    }

    func testHoldsAtMost100ReportsDroppingTheOldestWithOneWarning() throws {
        let player = FakePlayer()
        let ads = try join(player)
        player.load(LensPlayerSource(url: Self.urlA))
        for i in 0..<150 { ads.emitCustom("held", payload: LensPayload(custom: ["i": i])) }
        XCTAssertEqual(warnings.filter { $0.contains("dropping the oldest") }.count, 1)
        player.fire(.play)
        let held = delivered.filter { $0.customName == "held" }
        XCTAssertEqual(held.count, 100)
        XCTAssertEqual(held.first?.keys?["i"] as? Int, 50)
    }

    func testAReportFromAnotherThreadBeforePlaybackIsHeldLikeAnyOther() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.load(LensPlayerSource(url: Self.urlA))
        onBackground { lens.emitCustom("probe") }
        drainMainQueue()
        XCTAssertEqual(delivered.count, 0)
        player.fire(.play)
        XCTAssertEqual(delivered.map { $0.customName ?? $0.playbackState }, ["probe", "s"])
        XCTAssertTrue(player.snapshotReads.allSatisfy { $0 })
    }

    // MARK: playback states

    private static let movie = "https://cdn.example.com/vod/movie.m3u8?token=secret#t=10"

    func testReportsEachObservedTransitionOnceWithStartupAndStarvationKeys() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.load(LensPlayerSource(url: Self.movie))
        player.fire(.play)
        clock += 800
        player.set { $0.paused = false }
        player.fire(.playing)
        clock += 3000
        player.fire(.waiting)
        clock += 1500
        player.fire(.playing)
        player.set { $0.paused = true }
        player.fire(.pause)
        player.play()
        player.fire(.seeking)
        player.fire(.waiting)  // still seeking, not rebuffering
        player.fire(.seeked)
        player.set {
            $0.ended = true
            $0.paused = true
        }
        player.fire(.pause)
        player.fire(.ended)
        lens.dispose()  // ended already closed the story: no quit

        XCTAssertEqual(states(), ["s", "p", "r", "p", "a", "p", "k", "p", "a", "e"])
        XCTAssertTrue(reports().allSatisfy { $0.namespace == "lens" })
        let ps = reports("ps")
        XCTAssertEqual(status(ps[0])["su"], .flag(true))
        XCTAssertEqual(status(ps[0])["pr"], .number(0))
        XCTAssertEqual(status(ps[1])["msd"], .number(800))
        XCTAssertNil(status(ps[1])["su"])
        XCTAssertNil(status(ps[1])["pr"])
        XCTAssertEqual(status(ps[2])["bs"], .flag(true))
        XCTAssertEqual(status(ps[2])["su"], .flag(true))
        XCTAssertEqual(status(ps[2])["bsa"], list(1))
        XCTAssertEqual(status(ps[3])["bs"], .flag(true))
        XCTAssertEqual(status(ps[3])["bsd"], list(1500))
        XCTAssertEqual(status(ps[3])["bsa"], list(1))
        XCTAssertEqual(status(ps[3])["bsda"], list(1500))
        XCTAssertEqual(ps.filter { status($0)["msd"] != nil }.count, 1)
        XCTAssertEqual(ps.filter { status($0)["bsd"] != nil }.count, 1)
    }

    func testAReplayAfterTheEndIsANewStartupInTheSameSessionWithoutASecondMsd() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.load(LensPlayerSource(url: Self.movie))
        player.play()
        let sid = lens.session?.sessionId
        player.set { $0.ended = true }
        player.fire(.ended)
        player.set { $0.ended = false }
        player.play()
        XCTAssertEqual(states(), ["s", "p", "e", "s", "p"])
        XCTAssertEqual(lens.session?.sessionId, sid)
        XCTAssertEqual(reports("ps").filter { status($0)["msd"] != nil }.count, 1)
    }

    func testAnEndedSessionCarriesOnHeartbeatsContinueWithStaEAndItEndsWithoutAQuit() throws {
        captureTickers()
        let player = FakePlayer()
        let lens = try join(player, heartbeatMs: 30_000)
        player.load(LensPlayerSource(url: Self.movie))
        player.play()
        player.set {
            $0.ended = true
            $0.paused = true
        }
        player.fire(.ended)
        XCTAssertEqual(running.count, 1)
        running[0].tick()
        lens.dispose()
        XCTAssertEqual(reports().map(\.type), ["ps", "t", "ps", "ps", "t"])
        XCTAssertEqual(reports().map(\.playbackState), ["s", "s", "p", "e", "e"])
    }

    func testAFatalErrorReportsEThenStaFAndEndsTheSessionNoQuitNoHeartbeat() throws {
        captureTickers()
        let player = FakePlayer()
        let lens = try join(player, heartbeatMs: 30_000)
        player.load(LensPlayerSource(url: Self.movie))
        player.play()
        let failed = lens.session?.sessionId
        player.fire(
            .error(
                fatal: false, code: "NET-RETRY",
                message: "The network connection was lost. (NSURLErrorDomain -1005)"))
        player.fire(.error(fatal: true, code: "DECODE\nÉ"))
        XCTAssertNil(lens.session)
        XCTAssertEqual(running.count, 0)
        player.fire(.pause)
        player.fire(.waiting)
        lens.dispose()
        XCTAssertEqual(reports().map(\.type), ["ps", "t", "ps", "e", "e", "ps"])
        XCTAssertEqual(reports().map(\.playbackState), ["s", "s", "p", "p", "p", "f"])
        XCTAssertEqual(
            reports("e").map { status($0)["ec"] },
            [.strings(["NET-RETRY"]), .strings(["DECODE ?"])])
        XCTAssertTrue(reports().allSatisfy { $0.session.sessionId == failed })
    }

    func testPlaybackRequestedAgainAfterAFatalErrorStartsAFreshSession() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.load(LensPlayerSource(url: Self.movie))
        player.play()
        let failed = lens.session?.sessionId
        player.fire(.error(fatal: true, code: "NET"))
        player.set { $0.paused = true }
        player.play()
        XCTAssertNotEqual(lens.session?.sessionId, failed)
        XCTAssertEqual(states(), ["s", "p", "f", "s", "p"])
        XCTAssertEqual(
            reports("ps").map { $0.session.sessionId == failed }, [true, true, true, false, false])
    }

    func testAFatalErrorBeforeAnyPlayRequestStartsTheSessionAndEndsItHeldReportsEThenF() throws {
        captureTickers()
        let player = FakePlayer()
        let lens = try join(player, heartbeatMs: 30_000)
        player.load(LensPlayerSource(url: Self.movie))
        lens.emitCustom("at_source")
        player.fire(.error(fatal: false, code: "NET-RETRY"))
        player.fire(.error(fatal: true, code: "MEDIA_ERR_SRC_NOT_SUPPORTED"))
        XCTAssertEqual(reports().map(\.type), ["ce", "e", "e", "ps"])
        XCTAssertEqual(reports().map(\.playbackState), [nil, nil, nil, "f"])
        XCTAssertEqual(
            reports("e").map { status($0)["ec"] },
            [.strings(["NET-RETRY"]), .strings(["MEDIA_ERR_SRC_NOT_SUPPORTED"])])
        XCTAssertEqual(Set(reports().map(\.session.sessionId)).count, 1)
        // Ended at once: no heartbeat, no quit, and a later play request starts afresh.
        XCTAssertNil(lens.session)
        XCTAssertEqual(running.count, 0)
        let failed = reports()[0].session.sessionId
        player.fire(.play)
        XCTAssertEqual(reports().dropFirst(4).map(\.type), ["ps", "t"])
        XCTAssertEqual(reports().dropFirst(4).map(\.playbackState), ["s", "s"])
        XCTAssertNotEqual(lens.session?.sessionId, failed)
    }

    func testStateChangesReachADestinationWithHeartbeatsOffOnlyETFollowsThatSetting() throws {
        captureTickers()
        var hooked: [LensEvent] = []
        var ingested: [LensEvent] = []
        Lens.sinkForTesting = { destination, event in
            if destination.heartbeat == false {
                hooked.append(event)
            } else {
                ingested.append(event)
            }
        }
        let player = FakePlayer()
        let hook = LensDestination(url: "https://hook.example/", format: .json, heartbeat: false)
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads", destinations: [ingest, hook], heartbeatMs: 30_000,
                player: player))
        player.load(LensPlayerSource(url: Self.movie, autoplay: true))
        player.set { $0.paused = true }
        player.fire(.pause)
        running[0].tick()
        lens.dispose()
        XCTAssertEqual(hooked.map(\.type), ["ps", "ps", "ps"])
        XCTAssertEqual(hooked.map(\.playbackState), ["s", "a", "q"])
        XCTAssertTrue(ingested.contains { $0.type == "t" })
    }

    func testStaFCarriesTheEndOfSessionContextTheErrorReportDoesNot() throws {
        let player = FakePlayer()
        let lens = try join(player)
        lens.setHeartbeatPayload(LensPayload(custom: ["pod": "mid-1"]))
        player.load(LensPlayerSource(url: Self.movie, autoplay: true))
        player.fire(.error(fatal: true, code: "NET"))
        XCTAssertEqual(reports().map(\.type), ["ps", "e", "ps"])
        XCTAssertEqual(reports().map(\.playbackState), ["s", "s", "f"])
        XCTAssertNil(reports()[0].keys)
        XCTAssertNil(reports()[1].keys)
        XCTAssertEqual(reports()[2].keys?["pod"] as? String, "mid-1")
    }

    func testAutoplayStartsTheStartupClockAtTheSource() throws {
        let player = FakePlayer()
        _ = try join(player)
        player.load(LensPlayerSource(url: Self.movie, autoplay: true))
        clock += 700
        player.set { $0.paused = false }
        player.fire(.playing)
        XCTAssertEqual(states(), ["s", "p"])
        XCTAssertEqual(status(reports("ps")[1])["msd"], .number(700))
    }

    func testPreloadingIsWhatThePlayerHoldsBeforePlaybackIsRequestedNotItsPreloadSetting() throws {
        let player = FakePlayer()
        _ = try join(player)
        // The setting alone means nothing: media may never come.
        player.load(LensPlayerSource(url: Self.movie, preload: .auto))
        // Media arriving is preloading, whatever the setting — held until playback is requested.
        clock += 100
        player.change { $0.hasMediaData = true }
        XCTAssertEqual(states(), [])
        clock += 300
        player.fire(.play)
        clock += 500
        player.set { $0.paused = false }
        player.fire(.playing)
        XCTAssertEqual(states(), ["d", "s", "p"])
        XCTAssertEqual(reports("ps").map(\.timestamp), [1_100, 1_400, 1_900])
        // The startup clock runs from the play request, not from the preload.
        XCTAssertEqual(status(reports("ps")[2])["msd"], .number(500))
    }

    func testAPreloadSettingOfOffWithMediaArrivingAnywayStillReportsDOncePlayed() throws {
        let player = FakePlayer()
        _ = try join(player)
        player.load(LensPlayerSource(url: Self.movie, preload: .off))
        player.change { $0.hasMediaData = true }
        player.fire(.play)
        XCTAssertEqual(states(), ["d", "s"])
    }

    func testAChangeThatPreloadsReportsDBeforeTheEventsItBrings() throws {
        let player = FakePlayer()
        _ = try join(player)
        func ladder(_ loading: String) -> [LensTrack] {
            [
                LensTrack(
                    id: "v", kind: .video, selected: true,
                    renditions: [
                        LensRendition(id: "lo", bitrate: 1_000_000),
                        LensRendition(id: "hi", bitrate: 4_000_000),
                    ],
                    loadingRenditionId: loading)
            ]
        }
        player.change { $0.tracks = ladder("lo") }
        player.load(LensPlayerSource(url: Self.movie))
        player.change {
            $0.tracks = ladder("hi")
            $0.hasMediaData = true
        }
        XCTAssertEqual(reports().count, 0)
        player.fire(.play)
        XCTAssertEqual(reports().map(\.type), ["ps", "bc", "ps"])
        XCTAssertEqual(reports().map(\.playbackState), ["d", "d", "s"])
    }

    func testWithoutThePushBufferedMediaInASnapshotReadAtAFactCountsToo() throws {
        let player = FakePlayer()
        _ = try join(player)
        player.load(LensPlayerSource(url: Self.movie))
        player.set { $0.buffered = [LensBufferedRanges(ranges: [LensTimeRange(start: 0, end: 6)])] }
        player.change { $0.muted = false }
        player.fire(.play)
        XCTAssertEqual(states(), ["d", "s"])

        // A pushed false wins over a stale snapshot.
        delivered = []
        let other = FakePlayer()
        let otherLens = try join(other)
        other.set { $0.buffered = [LensBufferedRanges(ranges: [LensTimeRange(start: 0, end: 6)])] }
        other.change { $0.hasMediaData = false }
        other.load(LensPlayerSource(url: "https://cdn.example.com/vod/other.m3u8"))
        XCTAssertNil(otherLens.session)
        other.fire(.play)
        XCTAssertEqual(states(), ["s"])
    }

    func testMediaHeldAfterPlaybackWasRequestedIsNotPreloading() throws {
        let player = FakePlayer()
        _ = try join(player)
        player.load(LensPlayerSource(url: Self.movie))
        player.fire(.play)
        player.change { $0.hasMediaData = true }
        player.fire(.pause)
        player.change { $0.hasMediaData = false }
        player.change { $0.hasMediaData = true }
        XCTAssertEqual(states(), ["s", "a"])
    }

    /// Every combination: the preload setting never decides anything; autoplay
    /// is a play request; media loaded before the request shows as a held `d`.
    func testTheSessionStartsAtTheFirstPlayRequestWhateverThePreloadAndAutoplaySettings() throws {
        for preload in [nil, .off, .metadata, .auto] as [LensPreload?] {
            for autoplay in [false, true] {
                for media in [false, true] {
                    for play in [false, true] {
                        let name =
                            "preload \(preload.map { "\($0)" } ?? "unset"), autoplay \(autoplay), media \(media), play \(play)"
                        Lens.resetConfigurationForTesting()
                        delivered = []
                        clock = 1_000
                        captureTickers()
                        let player = FakePlayer()
                        let lens = try join(player, heartbeatMs: 30_000)
                        player.load(
                            LensPlayerSource(url: Self.movie, autoplay: autoplay, preload: preload))
                        lens.emitCustom("at_source")
                        clock = 2_000
                        if media { player.change { $0.hasMediaData = true } }
                        clock = 3_000
                        if play { player.fire(.play) }

                        let started = autoplay || play
                        // The request came with the source under autoplay; media after it is not a preload.
                        let expected: [String?] =
                            autoplay ? ["s"] : play ? (media ? ["d", "s"] : ["s"]) : []
                        let times: [Int64] =
                            autoplay ? [1_000] : play ? (media ? [2_000, 3_000] : [3_000]) : []
                        XCTAssertEqual(states(), expected, name)
                        XCTAssertEqual(reports("ps").map(\.timestamp), times, name)
                        XCTAssertEqual(lens.session == nil, !started, name)
                        XCTAssertEqual(running.count, started ? 1 : 0, name)
                        // What was emitted at the source goes out with the session, or never.
                        XCTAssertEqual(reports("ce").map(\.timestamp), started ? [1_000] : [], name)
                        XCTAssertEqual(!reports("t").isEmpty, started, name)

                        // Removing the source: a started session quits; otherwise nothing was ever sent.
                        player.load(nil)
                        XCTAssertEqual(states().filter { $0 == "q" }.count, started ? 1 : 0, name)
                        if !started { XCTAssertEqual(delivered.count, 0, name) }
                    }
                }
            }
        }
    }

    func testAPreloadTheSourceReplacesBeforeAnyPlayRequestSendsNothingAndHoldsNothingOver() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.load(LensPlayerSource(url: Self.movie, preload: .auto))
        player.change { $0.hasMediaData = true }
        lens.emitCustom("for_first")
        player.properties = LensPlayerProperties()
        player.load(LensPlayerSource(url: "https://cdn.example.com/vod/next.m3u8"))
        player.fire(.play)
        XCTAssertEqual(reports().map { $0.customName ?? $0.playbackState }, ["s"])
    }

    func testABlockedAutoplayStillCountsAsThePlayRequest() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.load(LensPlayerSource(url: Self.movie, autoplay: true))
        player.fire(.waitingForInput)
        XCTAssertEqual(states(), ["s", "w"])
        XCTAssertNotNil(lens.session)
    }

    func testJoiningLatePreloadedButUnplayedWaitsForPlayPastZeroOrPlayingHasBeenPlayed() throws {
        // Preloaded, paused at zero: no play request yet.
        let preloaded = FakePlayer()
        preloaded.source = LensPlayerSource(url: Self.movie)
        preloaded.properties = LensPlayerProperties(hasMediaData: true)
        let first = try join(preloaded)
        XCTAssertNil(first.session)
        preloaded.fire(.play)
        XCTAssertEqual(states(), ["d", "s"])

        // Paused past zero, or playing: it was played before Lens joined.
        for (paused, state) in [(true, "a"), (false, "p")] {
            delivered = []
            let player = FakePlayer()
            player.source = LensPlayerSource(url: Self.movie)
            player.set {
                $0.currentTime = 12
                $0.paused = paused
            }
            let lens = try join(player)
            XCTAssertNotNil(lens.session)
            XCTAssertEqual(states(), [state])
        }
    }

    func testAPlayerThatNeverReportsPlayStillReachesPWithoutAStartupTime() throws {
        let player = FakePlayer()
        _ = try join(player)
        player.load(LensPlayerSource(url: Self.movie))
        player.set { $0.paused = false }
        player.fire(.playing)
        XCTAssertEqual(states(), ["p"])
        XCTAssertNil(status(reports("ps")[0])["msd"])
    }

    func testWaitingForInputReportsWThePlayThatFollowsRestartsTheStartupClock() throws {
        let player = FakePlayer()
        _ = try join(player)
        player.load(LensPlayerSource(url: Self.movie, autoplay: true))
        clock += 100
        player.fire(.waitingForInput)
        clock += 5000
        player.fire(.pause)  // a blocked autoplay's pause is not a user pause
        player.fire(.play)
        clock += 300
        player.set { $0.paused = false }
        player.fire(.playing)
        XCTAssertEqual(states(), ["s", "w", "s", "p"])
        XCTAssertEqual(status(reports("ps")[3])["msd"], .number(300))
    }

    func testSeekingFromPauseLandsBackInPauseStartupAndRebufferingAreNotSeekable() throws {
        let player = FakePlayer()
        _ = try join(player)
        player.load(LensPlayerSource(url: Self.movie))
        player.fire(.play)
        player.fire(.seeking)  // during startup: still starting
        player.fire(.waiting)  // during startup: not rebuffering
        player.play()
        player.set { $0.paused = true }
        player.fire(.pause)
        player.fire(.seeking)
        player.fire(.seeked)
        XCTAssertEqual(states(), ["s", "p", "a", "k", "a"])
    }

    func testSuLastsFromAStartupSeekOrRebufferUntilTheBufferIsStable() throws {
        let player = FakePlayer()
        let lens = try join(player)
        func su() -> Bool { status(probe(lens))["su"] == .flag(true) }
        player.change { $0.bufferStable = false }
        player.load(LensPlayerSource(url: Self.movie))
        player.play()
        XCTAssertTrue(su())  // playing, but the buffer has not reached its target yet
        player.change { $0.bufferStable = true }
        XCTAssertFalse(su())
        player.change { $0.bufferStable = false }
        XCTAssertFalse(su())  // only the first time it reaches the target counts
        player.fire(.seeking)
        player.fire(.seeked)
        XCTAssertTrue(su())
        player.change { $0.bufferStable = true }
        XCTAssertFalse(su())
        // A seek the buffer already covers is not urgent.
        player.fire(.seeking)
        player.fire(.seeked)
        XCTAssertFalse(su())

        // Without the signal, the buffered media against the target decides.
        player.set {
            $0.currentTime = 10
            $0.buffered = [
                LensBufferedRanges(kind: .video, ranges: [LensTimeRange(start: 0, end: 14)])
            ]
        }
        player.change {
            $0.bufferStable = nil
            $0.targetBuffer = 8
        }
        player.fire(.waiting)
        player.fire(.playing)
        XCTAssertTrue(su())
        player.set {
            $0.buffered = [
                LensBufferedRanges(kind: .video, ranges: [LensTimeRange(start: 0, end: 18)])
            ]
        }
        XCTAssertFalse(su())
    }

    func testSuHoldsWhenTheAdapterPushesTheBufferDropJustAfterTheFactThatCausedIt() throws {
        let player = FakePlayer()
        let lens = try join(player)
        func su() -> Bool { status(probe(lens))["su"] == .flag(true) }
        player.change { $0.bufferStable = true }
        player.load(LensPlayerSource(url: Self.movie))
        player.play()
        XCTAssertFalse(su())

        // A seek outside the buffer, the fact first and then the drop.
        player.fire(.seeking)
        player.change { $0.bufferStable = false }
        XCTAssertTrue(su())
        player.fire(.seeked)
        XCTAssertTrue(su())
        player.change { $0.bufferStable = true }
        XCTAssertFalse(su())
        // Once the buffer first reached its target, a dip leaves the window closed.
        player.change { $0.bufferStable = false }
        XCTAssertFalse(su())
        player.change { $0.bufferStable = true }

        // A rebuffer the same way round.
        player.fire(.waiting)
        player.change { $0.bufferStable = false }
        XCTAssertTrue(su())
        player.fire(.playing)
        player.change { $0.bufferStable = true }
        XCTAssertFalse(su())

        // A seek inside the buffer never drops it, and stays quiet.
        player.fire(.seeking)
        player.fire(.seeked)
        XCTAssertFalse(su())
        // Outside the urgent states, a drop alone opens nothing.
        player.change { $0.bufferStable = false }
        XCTAssertFalse(su())
    }

    func testReadingThePlayerForAReportNeverClosesTheSuWindowByItself() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.change { $0.bufferStable = false }
        player.load(LensPlayerSource(url: Self.movie))
        player.play()
        // The window closes on the input that says the buffer is stable...
        player.change { $0.bufferStable = true }
        player.change { $0.bufferStable = false }
        XCTAssertNil(status(probe(lens))["su"])
        // ...and building reports leaves an open one open.
        player.fire(.seeking)
        player.fire(.seeked)
        for _ in 0..<3 { lens.emitCustom("probe") }
        XCTAssertTrue(delivered.suffix(3).allSatisfy { status($0)["su"] == .flag(true) })
    }

    func testAFactFiredFromInsideSnapshotWaitsForTheFactOrReportBeingHandled() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.load(LensPlayerSource(url: Self.movie))
        player.fire(.play)
        var inject: LensPlayerFact?
        player.duringSnapshot = { [weak player] in
            guard let fact = inject else { return }
            inject = nil
            player?.fire(fact)
        }
        player.set { $0.paused = false }
        inject = .pause
        player.fire(.playing)
        // The player's last word was pause, and that is where Lens ends.
        XCTAssertEqual(states(), ["s", "p", "a"])

        inject = .playing
        lens.emitCustom("probe")
        // The report reads one moment; the fact fired during the read comes after it.
        XCTAssertEqual(reports().suffix(2).map(\.type), ["ce", "ps"])
        XCTAssertEqual(reports().suffix(2).map(\.playbackState), ["a", "p"])
    }

    func testAnAdapterFiringAFactOnEverySnapshotReadIsCutOffWithOneWarning() throws {
        let player = FakePlayer()
        _ = try join(player)
        player.load(LensPlayerSource(url: Self.movie))
        player.change { $0.muted = false }
        var hostile = true
        var muted = false
        player.duringSnapshot = { [weak player] in
            guard hostile else { return }
            muted.toggle()
            player?.change { $0.muted = muted }
        }
        player.fire(.play)
        XCTAssertEqual(warnings.filter { $0.contains("dropping the rest") }.count, 1)
        let toggles = reports().filter { $0.type == "m" || $0.type == "um" }
        XCTAssertGreaterThan(toggles.count, 0)
        XCTAssertLessThanOrEqual(toggles.count, 64)
        hostile = false
        player.set { $0.paused = false }
        player.fire(.playing)
        XCTAssertEqual(states(), ["s", "p"])
    }

    func testFactsBeforeTheInitialOneAreTakenAsTheyComeALateInitialIsARepeat() throws {
        let player = SilentPlayer()
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads", destinations: [ingest], heartbeatMs: 0, player: player))
        player.listener?(.source(Self.autoplaying, properties: .init()))
        let sid = try XCTUnwrap(lens.session).sessionId
        player.listener?(.initial(source: Self.autoplaying, properties: .init()))
        XCTAssertEqual(lens.session?.sessionId, sid)
        XCTAssertFalse(delivered.contains { $0.playbackState == "q" })
    }

    /// Subscribes without delivering `initial`, breaking the contract.
    private final class SilentPlayer: LensPlayerAdapter {
        let playerName = "silent"
        var listener: ((LensPlayerFact) -> Void)?

        func subscribe(_ listener: @escaping (LensPlayerFact) -> Void) -> () -> Void {
            self.listener = listener
            return {}
        }

        func snapshot() -> LensPlayerSnapshot {
            LensPlayerSnapshot(currentTime: 0, paused: true, ended: false)
        }
    }

    // MARK: player sources

    func testTheSessionTakesItsContentIdFromTheSourceOrFromTheUrlWithoutQueryAndFragment() throws {
        let player = FakePlayer()
        let lens = try join(player, namespace: "live")
        player.load(
            LensPlayerSource(
                url: "https://CDN.example.com/vod/movie.mpd?token=secret#t=10", autoplay: true))
        let event = probe(lens)
        XCTAssertEqual(event.contentId, "https://CDN.example.com/vod/movie.mpd")
        XCTAssertEqual(event.hostname, "cdn.example.com")
        XCTAssertEqual(event.streamingFormat, "d")
        player.load(LensPlayerSource(url: Self.urlA, contentId: "movie-2", autoplay: true))
        XCTAssertEqual(probe(lens).contentId, "movie-2")
        // Credentials in the URL never reach the wire, even with an @ in the password.
        player.load(
            LensPlayerSource(url: "https://user:p@ss@cdn.example.com/vod/movie.mpd", autoplay: true)
        )
        let credentialed = probe(lens)
        XCTAssertEqual(credentialed.contentId, "https://cdn.example.com/vod/movie.mpd")
        XCTAssertEqual(credentialed.hostname, "cdn.example.com")
    }

    func testSfComesFromTheMimeTypeElseTheExtensionStFollowsTheLiveProperties() throws {
        let player = FakePlayer()
        let lens = try join(player, namespace: "live")
        player.change { $0.live = true }
        player.load(
            LensPlayerSource(
                url: "https://cdn.example.com/stream", mimeType: "application/vnd.apple.mpegurl",
                autoplay: true))
        XCTAssertEqual(probe(lens).streamingFormat, "h")
        XCTAssertEqual(probe(lens).streamType, "l")
        player.change { $0.lowLatency = true }
        XCTAssertEqual(probe(lens).streamType, "ll")
        // An event playlist that ends turns into VOD.
        player.change { $0.live = false }
        XCTAssertEqual(probe(lens).streamType, "v")
        player.load(
            LensPlayerSource(
                url: "https://cdn.example.com/clip.mp4", mimeType: "video/mp4", autoplay: true))
        XCTAssertEqual(probe(lens).streamingFormat, "o")
        player.load(LensPlayerSource(url: "https://cdn.example.com/clip", autoplay: true))
        XCTAssertNil(probe(lens).streamingFormat)
        player.load(
            LensPlayerSource(url: "https://cdn.example.com/live.isml/Manifest", autoplay: true))
        XCTAssertEqual(probe(lens).streamingFormat, "s")
    }

    func testLongOrNonAsciiUrlsStillYieldAValidContentIdAnInvalidContentIdFallsBack() throws {
        let player = FakePlayer()
        let lens = try join(player, namespace: "live")
        player.load(
            LensPlayerSource(
                url: "https://cdn.example.com/\(String(repeating: "é", count: 100))",
                contentId: "bad\nid", autoplay: true))
        let contentId = try XCTUnwrap(probe(lens).contentId)
        XCTAssertTrue(contentId.hasPrefix("https://cdn.example.com/%C3%A9%C3%A9"))
        XCTAssertLessThanOrEqual(contentId.utf16.count, 128)
        XCTAssertTrue(Validation.matches(contentId, Validation.contentIdPattern))

        // An astral character is one code point, encoded whole.
        player.load(LensPlayerSource(url: "https://cdn.example.com/🎬.m3u8", autoplay: true))
        XCTAssertEqual(probe(lens).contentId, "https://cdn.example.com/%F0%9F%8E%AC.m3u8")
    }

    func testAnUnusableSourceIsNoSource() throws {
        let player = FakePlayer()
        let lens = try join(player, namespace: "live")
        player.load(LensPlayerSource(url: ""))
        player.load(LensPlayerSource(contentId: ""))
        player.load(LensPlayerSource(url: "", contentId: "", mimeType: "video/mp4"))
        player.play()
        XCTAssertNil(lens.session)
    }

    func testASourceNamedOnlyByItsContentIdStartsASession() throws {
        let player = FakePlayer()
        let lens = try join(player, namespace: "live")
        player.load(
            LensPlayerSource(
                contentId: "dai-asset-1", mimeType: "application/x-mpegurl", autoplay: true))
        XCTAssertNotNil(lens.session)
        let event = probe(lens)
        XCTAssertEqual(event.contentId, "dai-asset-1")
        XCTAssertEqual(event.streamingFormat, "h")
        XCTAssertNil(event.hostname)
        player.load(LensPlayerSource(url: "", contentId: "dai-asset-2", autoplay: true))
        XCTAssertEqual(probe(lens).contentId, "dai-asset-2")
    }

    func testARepeatedInitialKeepsASessionNamedOnlyByItsContentId() throws {
        let player = FakePlayer()
        let lens = try join(player, namespace: "live")
        player.load(LensPlayerSource(contentId: "dai-asset-1", autoplay: true))
        let sid = lens.session?.sessionId
        player.fire(
            .initial(source: LensPlayerSource(contentId: "dai-asset-1"), properties: .init()))
        XCTAssertEqual(lens.session?.sessionId, sid)
        player.fire(
            .initial(
                source: LensPlayerSource(contentId: "dai-asset-2", autoplay: true),
                properties: .init()))
        XCTAssertNotEqual(lens.session?.sessionId, sid)
    }

    func testARepeatedInitialComparesUrlAndContentIdAsAPairNeverAcrossFields() throws {
        let player = FakePlayer()
        let lens = try join(player, namespace: "live")
        player.load(LensPlayerSource(url: "x", autoplay: true))
        let first = lens.session?.sessionId
        player.fire(
            .initial(source: LensPlayerSource(contentId: "x", autoplay: true), properties: .init()))
        let second = lens.session?.sessionId
        XCTAssertNotEqual(second, first)
        player.fire(
            .initial(
                source: LensPlayerSource(url: Self.urlA, contentId: "c1", autoplay: true),
                properties: .init())
        )
        let third = lens.session?.sessionId
        player.fire(
            .initial(
                source: LensPlayerSource(url: Self.urlA, contentId: "c2", autoplay: true),
                properties: .init())
        )
        XCTAssertNotEqual(lens.session?.sessionId, third)
    }

    func testAContinuationKeepsTheSidAndItsCidHAndCReportOnlyWhatChanged() throws {
        let player = FakePlayer()
        let lens = try join(player, namespace: "live")
        player.load(LensPlayerSource(url: Self.urlA, contentId: "movie-1", autoplay: true))
        let sid = lens.session?.sessionId
        delivered = []
        player.load(
            LensPlayerSource(url: "https://cdn-a.example.com/fallback.m3u8", contentId: "movie-1"),
            continuation: true)
        XCTAssertEqual(delivered.count, 0)
        // A CDN failover: the host changes, the content does not.
        player.load(
            LensPlayerSource(url: "https://cdn-b.example.com/other.m3u8"), continuation: true)
        // Only a content ID the source names changes the cid.
        player.load(
            LensPlayerSource(url: "https://cdn-b.example.com/other.m3u8", contentId: "movie-2"),
            continuation: true)
        XCTAssertEqual(delivered.map(\.type), ["h", "c"])
        XCTAssertEqual(delivered.map(\.contentId), ["movie-1", "movie-2"])
        XCTAssertEqual(delivered.map(\.hostname), ["cdn-b.example.com", "cdn-b.example.com"])
        XCTAssertTrue(delivered.allSatisfy { $0.session.sessionId == sid })
    }

    func testAFallbackKeepsACidDerivedFromTheFirstUrlReportingOnlyTheHost() throws {
        let player = FakePlayer()
        _ = try join(player, namespace: "live")
        player.load(LensPlayerSource(url: Self.urlA, autoplay: true))
        delivered = []
        player.load(
            LensPlayerSource(url: "https://cdn-b.example.com/movie.m3u8"), continuation: true)
        XCTAssertEqual(delivered.map(\.type), ["h"])
        XCTAssertEqual(delivered.map(\.contentId), [Self.urlA])
    }

    func testANewSourceStartsFromItsOwnPropertiesNeverTheOldSources() throws {
        let player = FakePlayer()
        let lens = try join(player, namespace: "live")
        // Source A: low-latency live, preloaded, then playing with media buffered.
        player.change {
            $0.live = true
            $0.lowLatency = true
            $0.hasMediaData = true
        }
        player.load(LensPlayerSource(url: Self.urlA))
        player.play()
        player.set {
            $0.buffered = [LensBufferedRanges(ranges: [LensTimeRange(start: 0, end: 20)])]
        }
        XCTAssertEqual(probe(lens).streamType, "ll")

        // Source B, VOD, no preload: the adapter starts its properties over, while
        // the snapshot read as the source changes still holds A's media.
        player.properties = LensPlayerProperties(live: false)
        player.load(LensPlayerSource(url: "https://cdn-a.example.com/other.m3u8"))
        XCTAssertNil(lens.session)
        XCTAssertEqual(states().suffix(1), ["q"])
        player.fire(.play)
        XCTAssertEqual(states().suffix(2), ["q", "s"])
        XCTAssertEqual(probe(lens).streamType, "v")
    }

    func testMediaFoundAtALaterFactReadAfterTheSourceChangedIsPreloading() throws {
        let player = FakePlayer()
        let lens = try join(player, namespace: "live")
        player.set {
            $0.buffered = [LensBufferedRanges(ranges: [LensTimeRange(start: 0, end: 20)])]
        }
        player.load(LensPlayerSource(url: Self.urlA))
        player.fire(.seeking)
        XCTAssertNil(lens.session)
        player.fire(.play)
        XCTAssertEqual(delivered.map(\.playbackState), ["d", "s"])
    }

    func testANewSourceQuitsTheOldSessionAndMintsAnotherRemovingTheSourceQuits() throws {
        let player = FakePlayer()
        let lens = try join(player, namespace: "live")
        player.load(LensPlayerSource(url: Self.urlA, autoplay: true))
        let first = lens.session?.sessionId
        player.load(LensPlayerSource(url: "https://cdn-a.example.com/next.m3u8", autoplay: true))
        let second = lens.session?.sessionId
        XCTAssertNotEqual(second, first)
        player.load(nil)
        XCTAssertNil(lens.session)
        // A source set and replaced before any attempt to play leaves nothing behind.
        player.load(LensPlayerSource(url: "https://cdn-a.example.com/never.m3u8"))
        player.load(LensPlayerSource(url: "https://cdn-a.example.com/also-never.m3u8"))
        player.load(nil)
        XCTAssertEqual(delivered.map(\.playbackState), ["s", "q", "s", "q"])
        XCTAssertEqual(delivered.map(\.session.sessionId), [first, first, second, second])
    }

    func testJoiningAPlayerMidPlaybackAttachesWithItsCurrentStateAndNoStartupTime() throws {
        let player = FakePlayer()
        player.source = LensPlayerSource(url: Self.urlA)
        player.set {
            $0.paused = false
            $0.currentTime = 42
        }
        let lens = try join(player, namespace: "live")
        XCTAssertNotNil(lens.session)
        XCTAssertEqual(delivered.map(\.playbackState), ["p"])
        XCTAssertEqual(status(delivered[0])["pt"], .number(42_000))
        XCTAssertNil(status(delivered[0])["msd"])
    }

    // MARK: player keys

    private static let source = LensPlayerSource(url: "https://cdn.example.com/movie.mpd")
    private static let autoplaying = LensPlayerSource(
        url: "https://cdn.example.com/movie.mpd", autoplay: true)

    private static let video = LensTrack(
        id: "video", kind: .video, selected: true,
        renditions: [
            LensRendition(id: "v1", bitrate: 1_800_000, height: 540),
            LensRendition(
                id: "v2", bitrate: 4_200_400, codecs: "dvh1.05.06", height: 1080, frameRate: 25,
                videoRange: .pq),
            LensRendition(id: "v3", bitrate: 6_000_000, averageBitrate: 4_900_000, height: 2160),
        ],
        loadingRenditionId: "v2", renderedRenditionId: "v1")

    private static let audio = LensTrack(
        id: "audio-en", kind: .audio, selected: true, language: "en",
        renditions: [LensRendition(id: "a1", bitrate: 256_000)],
        loadingRenditionId: "a1", renderedRenditionId: "a1")

    private func playing(_ player: FakePlayer) throws -> LensHandle {
        let lens = try join(player)
        player.load(Self.source)
        player.play()
        delivered = []
        return lens
    }

    func testEveryReportCarriesWhatThePlayerModelYieldsRoundedPerSpec() throws {
        let player = FakePlayer()
        player.properties = LensPlayerProperties(
            tracks: [
                Self.video, Self.audio,
                LensTrack(id: "sub-en", kind: .text, selected: true, label: "English"),
            ],
            targetBuffer: 30, playbackRate: 1.5, visibility: .visible, nonRendered: true)
        player.set {
            $0.buffered = [
                LensBufferedRanges(kind: .video, ranges: [LensTimeRange(start: 0, end: 16.3)]),
                LensBufferedRanges(kind: .audio, ranges: [LensTimeRange(start: 0, end: 14.1)]),
            ]
            $0.measuredThroughput = 87_049_000
            $0.droppedFrames = 10
            // Carried for reports to come: nothing below changes today's keys.
            $0.duration = 600
            $0.seekable = [LensTimeRange(start: 0, end: 600)]
            $0.viewWidth = 1280
            $0.viewHeight = 720
            $0.capabilities = LensPlayerCapabilities(
                dolbyVision: true, dolbyAudioCodecs: ["ac-3", "ec-3"])
        }
        let lens = try playing(player)
        player.set {
            $0.currentTime = 12.3456
            $0.droppedFrames = 13
        }
        let event = probe(lens)
        XCTAssertEqual(event.playbackState, "p")
        XCTAssertEqual(
            status(event),
            keys([
                "pt": .number(12_346),
                "pr": .number(1.5),
                // 4 s buffered against a 30 s target: still urgent after startup
                "su": .flag(true),
                "bl": split((4000, "v"), (1800, "a")),
                "tbl": list(30_000),
                "br": split((4200, "v"), (256, "a")),
                "pb": split((1800, "v"), (256, "a")),
                "tb": split((6000, "v"), (256, "a")),
                "lb": split((1800, "v"), (256, "a")),
                "mtp": list(87_000),
                // counted from the session start, not the decoder's lifetime
                "dfa": .number(3),
                "nr": .flag(true),
            ]))
    }

    func testACombinedBitrateReportsAggregatesAPartialLadderReportsNoTopOrLowest() throws {
        let player = FakePlayer()
        player.properties = LensPlayerProperties(tracks: [
            LensTrack(
                id: "variants", kind: .video, selected: true,
                renditions: [
                    LensRendition(id: "l0", bitrate: 800_000, combinedBitrate: true),
                    LensRendition(id: "l1", bitrate: 2_400_000, combinedBitrate: true),
                ],
                loadingRenditionId: "l1", renderedRenditionId: "l1")
        ])
        let lens = try playing(player)
        let combined = status(probe(lens))
        XCTAssertEqual(combined["ab"], list(2400))
        XCTAssertEqual(combined["tab"], list(2400))
        XCTAssertEqual(combined["lab"], list(800))
        XCTAssertNil(combined["br"])
        XCTAssertNil(combined["pb"])
        var partial = Self.video
        partial.partialLadder = true
        player.change { $0.tracks = [partial] }
        let keys = status(probe(lens))
        XCTAssertEqual(keys["br"], split((4200, "v")))
        XCTAssertNil(keys["tb"])
        XCTAssertNil(keys["lb"])
    }

    func testTheBufferRunsFromThePlayheadAcrossGapsAPlayerSkipsNotAcrossRealHoles() throws {
        let player = FakePlayer()
        let lens = try playing(player)
        player.set {
            $0.currentTime = 10
            $0.buffered = [
                LensBufferedRanges(ranges: [
                    LensTimeRange(start: 0, end: 12),
                    LensTimeRange(start: 12.3, end: 15),
                    LensTimeRange(start: 16.5, end: 30),
                ])
            ]
        }
        XCTAssertEqual(status(probe(lens))["bl"], list(5000))
        player.set { $0.currentTime = 20.2 }
        XCTAssertEqual(status(probe(lens))["bl"], list(9800))
        player.set { $0.currentTime = 31 }
        XCTAssertEqual(status(probe(lens))["bl"], list(0))
    }

    func testDroppedFramesCountFromTheSessionStartAcrossDecoderCounterResets() throws {
        let player = FakePlayer()
        player.set { $0.droppedFrames = 100 }
        let lens = try playing(player)
        player.set { $0.droppedFrames = 104 }
        XCTAssertEqual(status(probe(lens))["dfa"], .number(4))
        player.set { $0.droppedFrames = 2 }  // the decoder was recreated
        XCTAssertEqual(status(probe(lens))["dfa"], .number(6))
        player.load(LensPlayerSource(url: "https://cdn.example.com/next.mpd"))
        player.set { $0.droppedFrames = 9 }  // dropped before the next session started
        player.fire(.play)
        XCTAssertEqual(status(probe(lens))["dfa"], .number(0))
    }

    func testAnAdapterWithOnlyTheRequiredValuesYieldsThePlayheadAndTheRate() throws {
        let player = FakePlayer()
        let lens = try playing(player)
        player.set { $0.paused = true }
        player.fire(.pause)
        XCTAssertEqual(status(probe(lens)), keys(["pt": .number(0), "pr": .number(0)]))
    }

    func testUnknownAndHostileValuesAreOmittedNeverSentAsPlaceholders() throws {
        let player = FakePlayer()
        player.properties = LensPlayerProperties(
            tracks: [
                LensTrack(
                    id: "v", kind: .video, selected: true,
                    renditions: [
                        LensRendition(id: "x", bitrate: .nan),
                        LensRendition(id: "y", bitrate: -1),
                        LensRendition(id: "z", bitrate: .infinity),
                    ],
                    loadingRenditionId: "x", renderedRenditionId: "missing")
            ],
            targetBuffer: -1, playbackRate: .nan, volume: .nan)
        let lens = try playing(player)
        player.set {
            $0.currentTime = .nan
            $0.buffered = [
                LensBufferedRanges(ranges: [
                    LensTimeRange(start: 5, end: 1), LensTimeRange(start: .nan, end: 3),
                ])
            ]
            $0.measuredThroughput = -5
            $0.droppedFrames = -1
            $0.playheadDateTime = Date(timeIntervalSince1970: .infinity)
        }
        XCTAssertEqual(status(probe(lens)), StatusKeys())
    }

    func testCounterValuesAtTheEdgeOfIntNeverTrap() throws {
        let player = FakePlayer()
        let lens = try playing(player)
        for frames in [Int.max, 0, .max, 0, .max] {
            player.set { $0.droppedFrames = frames }
            _ = probe(lens)
        }
        XCTAssertNotNil(status(probe(lens))["dfa"])
    }

    func testLiveStreamsWithAProgramDateTimeReportPtAsEpochMillisecondsAndLtcFromIt() throws {
        let player = FakePlayer()
        player.properties = LensPlayerProperties(live: true)
        let lens = try playing(player)
        clock = 1_764_752_403_000
        player.set {
            $0.currentTime = 30
            $0.playheadDateTime = Date(timeIntervalSince1970: 1_764_752_400.000_4)
        }
        player.fire(.seeked)  // any fact refreshes the snapshot
        let keys = status(probe(lens))
        XCTAssertEqual(keys["pt"], .number(1_764_752_400_000))
        XCTAssertEqual(keys["ltc"], .number(3000))
        // A reference near the epoch is a broken clock, not a latency.
        player.set { $0.playheadDateTime = Date(timeIntervalSince1970: 1) }
        XCTAssertNil(status(probe(lens))["ltc"])
        player.change { $0.live = false }
        XCTAssertEqual(status(probe(lens))["pt"], .number(30_000))
    }

    func testPropertyChangesReportBcMUmPrBAndPePcOnRealChangesOnly() throws {
        let player = FakePlayer()
        player.properties = LensPlayerProperties(
            playbackRate: 1, muted: false, volume: 1, visibility: .visible,
            presentationMode: .inline)
        _ = try playing(player)
        player.change { $0.tracks = [Self.video] }  // the first selection is not a change
        var rendered = Self.video
        rendered.renderedRenditionId = "v2"
        player.change { $0.tracks = [rendered] }  // nor is what renders
        var loading = Self.video
        loading.loadingRenditionId = "v3"
        player.change { $0.tracks = [loading] }
        player.change { $0.muted = true }
        player.change { $0.muted = true }
        player.change {
            $0.muted = false
            $0.volume = 0  // volume zero is muted too
        }
        player.change { $0.volume = 0.4 }
        player.change { $0.playbackRate = 2 }
        player.set { $0.paused = true }
        player.fire(.pause)
        player.change { $0.playbackRate = 1 }  // the spec's pr event is for playing only
        player.change { $0.visibility = .hidden }
        player.change { $0.presentationMode = .pictureInPicture }  // a PiP window is visible
        player.change {
            $0.presentationMode = .fullscreen
            $0.visibility = .visible
        }
        XCTAssertEqual(
            delivered.map(\.type), ["bc", "m", "um", "pr", "ps", "b", "b", "pc", "pe"])
        XCTAssertEqual(status(delivered[0])["br"], split((6000, "v")))
        XCTAssertEqual(status(delivered[3])["pr"], .number(2))
        XCTAssertEqual(status(delivered[5])["bg"], .flag(true))
        XCTAssertNil(status(delivered[7])["bg"])
    }

    func testTheAppInTheBackgroundOrAViewOutOfSightReportsBAndBgPipStaysVisible() throws {
        var appHidden = false
        Lens.appHidden = { appHidden }
        func app(hidden: Bool) {
            appHidden = hidden
            PlayerObserver.appVisibilityChanged(hidden: hidden)
        }
        let player = FakePlayer()
        let lens = try playing(player)
        app(hidden: true)  // the user switched apps, which the adapter knows nothing of
        app(hidden: true)
        player.change { $0.visibility = .visible }  // the view is in place, the app still hidden
        app(hidden: false)
        player.change { $0.visibility = .hidden }  // scrolled out of view
        app(hidden: true)  // hidden either way
        player.change { $0.visibility = nil }  // the app alone still says hidden
        player.change { $0.presentationMode = .pictureInPicture }
        app(hidden: false)
        XCTAssertEqual(delivered.map(\.type), ["b", "b", "b", "b"])
        XCTAssertEqual(
            delivered.map { status($0)["bg"] }, [.flag(true), nil, .flag(true), nil])
        XCTAssertNil(status(probe(lens))["bg"])
        lens.dispose()
        let count = delivered.count
        app(hidden: true)
        XCTAssertEqual(delivered.count, count)
    }

    func testWithoutAnAppOnlyTheAdaptersViewCounts() throws {
        let player = FakePlayer()
        let lens = try playing(player)
        PlayerObserver.appVisibilityChanged(hidden: true)
        XCTAssertEqual(delivered.count, 0)
        XCTAssertNil(status(probe(lens))["bg"])
    }

    func testBAlternatesAgainstWhatWasLastKnownAcrossASpellOfNotKnowing() throws {
        let player = FakePlayer()
        player.properties = LensPlayerProperties(visibility: .visible)
        _ = try playing(player)
        player.change { $0.visibility = .hidden }
        player.change { $0.visibility = nil }  // no app: nothing is known now
        player.change { $0.visibility = .visible }  // the exit, though unknown came between
        player.change { $0.visibility = .hidden }
        XCTAssertEqual(delivered.map(\.type), ["b", "b", "b"])
        XCTAssertEqual(delivered.map { status($0)["bg"] }, [.flag(true), nil, .flag(true)])
    }

    func testARepeatedInitialIsAChangeNeverAFreshStart() throws {
        let player = FakePlayer()
        player.properties = LensPlayerProperties(muted: false)
        let lens = try playing(player)
        let sid = lens.session?.sessionId
        player.fire(.initial(source: Self.source, properties: LensPlayerProperties(muted: true)))
        XCTAssertEqual(lens.session?.sessionId, sid)
        XCTAssertEqual(delivered.map(\.type), ["m"])
        player.fire(
            .initial(
                source: LensPlayerSource(url: "https://cdn.example.com/next.mpd", autoplay: true),
                properties: .init()))
        XCTAssertNotEqual(lens.session?.sessionId, sid)
        player.fire(.initial(source: nil, properties: .init()))
        XCTAssertNil(lens.session)
    }

    /// Keeps its listener forever, however Lens releases it.
    private final class StubbornPlayer: LensPlayerAdapter {
        let playerName = "stubborn"
        var listener: ((LensPlayerFact) -> Void)?

        func subscribe(_ listener: @escaping (LensPlayerFact) -> Void) -> () -> Void {
            self.listener = listener
            listener(.initial(source: PlayerTests.source, properties: .init()))
            return {}
        }

        func snapshot() -> LensPlayerSnapshot {
            LensPlayerSnapshot(currentTime: 0, paused: false, ended: false)
        }
    }

    func testFactsAfterTheLastDisposeAreIgnoredEvenFromAnAdapterThatNeverReleased() throws {
        let player = StubbornPlayer()
        XCTAssertNil(player.playerVersion)
        let lens = try Lens.join(
            LensJoinOptions(
                namespace: "ads", destinations: [ingest], heartbeatMs: 0, player: player))
        lens.dispose()
        let count = delivered.count
        player.listener?(.source(Self.source, properties: .init()))
        player.listener?(.playing)
        XCTAssertEqual(delivered.count, count)
    }

    func testErrorCodesRideAsPrintableAsciiCutTo64() throws {
        let player = FakePlayer()
        _ = try playing(player)
        player.fire(.error(fatal: false, code: ""))
        player.fire(.error(fatal: false, code: String(repeating: "x", count: 80)))
        player.fire(.error(fatal: false, code: "\u{1}🎬\u{7F}é"))
        XCTAssertEqual(
            reports("e").map { status($0)["ec"] },
            [
                .strings(["unknown"]), .strings([String(repeating: "x", count: 64)]),
                // One unit at a time, as on web: the astral character is two.
                .strings([" ?? ?"]),
            ])
    }

    // MARK: player snapshots and the main queue

    func testAFactReadsThePlayerWhereItArrivesAReportLensTriggersReadsItWhenSent() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.load(Self.source)
        player.play()
        player.set {
            $0.currentTime = 61.5
            $0.paused = true
        }
        player.fire(.pause)
        player.set { $0.currentTime = 70 }
        lens.emitCustom("probe")
        XCTAssertEqual(
            delivered.suffix(2).map { status($0)["pt"] }, [.number(61_500), .number(70_000)])
        XCTAssertTrue(player.snapshotReads.allSatisfy { $0 })
    }

    func testTheQuitCannotWaitForAReadItCarriesTheLastSnapshot() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.load(Self.autoplaying)
        player.set { $0.currentTime = 5 }
        player.fire(.pause)
        let reads = player.snapshotReads.count
        player.set { $0.currentTime = 9 }
        TransportRuntime.terminationNotifier?()
        XCTAssertEqual(player.snapshotReads.count, reads)
        XCTAssertEqual(delivered.last?.playbackState, "q")
        XCTAssertEqual(status(delivered.last!)["pt"], .number(5000))
        lens.dispose()
    }

    func testAReportFromAnotherThreadWaitsForTheMainQueueAndReadsThePlayerThere() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.load(Self.source)
        player.play()
        player.set { $0.currentTime = 12 }
        onBackground { lens.emitCustom("probe") }
        drainMainQueue { self.delivered.contains { $0.customName == "probe" } }
        let event = try XCTUnwrap(delivered.first { $0.customName == "probe" })
        XCTAssertEqual(status(event)["pt"], .number(12_000))
        XCTAssertEqual(event.playbackState, "p")
        XCTAssertTrue(player.snapshotReads.allSatisfy { $0 })
    }

    func testAHeartbeatTickingOffTheMainQueueReadsThePlayerOnIt() throws {
        captureTickers()
        let player = FakePlayer()
        _ = try join(player, heartbeatMs: 30_000)
        player.load(Self.autoplaying)
        delivered = []
        let tick = try XCTUnwrap(running.first).tick
        onBackground { tick() }
        drainMainQueue { !self.delivered.isEmpty }
        XCTAssertEqual(delivered.map(\.type), ["t"])
        XCTAssertTrue(player.snapshotReads.allSatisfy { $0 })
    }

    func testATickOfACadenceThatStoppedOnItsWayToTheMainQueueSendsNothing() throws {
        captureTickers()
        let player = FakePlayer()
        let lens = try join(player, heartbeatMs: 30_000)
        player.load(Self.autoplaying)
        delivered = []
        let tick = try XCTUnwrap(running.first).tick
        // The main queue stays blocked until the tick has queued its report.
        let ticked = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            tick()
            ticked.signal()
        }
        ticked.wait()
        lens.setHeartbeatInterval(0)
        drainMainQueue()
        XCTAssertEqual(delivered.count, 0)
    }

    func testJoiningAndDisposingFromAnotherThreadCallTheAdapterOnTheMainQueue() throws {
        let player = FakePlayer()
        player.source = Self.autoplaying
        var lens: LensHandle?
        onBackground { lens = try? self.join(player) }
        drainMainQueue { player.subscribeCalls == 1 && lens?.session != nil }
        XCTAssertEqual(player.subscribedOnMain, [true])
        XCTAssertNotNil(lens?.session)
        onBackground { lens?.dispose() }
        drainMainQueue { player.listenerCount == 0 }
        XCTAssertEqual(player.releasedOnMain, [true])
        XCTAssertTrue(player.snapshotReads.allSatisfy { $0 })
    }

    func testAFactDeliveredOffTheMainQueueIsMovedThereWarnedOnce() throws {
        let player = FakePlayer()
        let lens = try join(player)
        player.load(Self.source)
        onBackground {
            player.fire(.play)
            player.fire(.playing)
        }
        drainMainQueue { self.states().count == 2 }
        XCTAssertEqual(states(), ["s", "p"])
        XCTAssertEqual(warnings.filter { $0.contains("off the main queue") }.count, 1)
        XCTAssertTrue(player.snapshotReads.allSatisfy { $0 })
        lens.dispose()
    }

    func testTheAdapterIsNeverCalledWhileLensHoldsItsLock() throws {
        let player = FakePlayer()
        let lens = try join(player)
        var free: [Bool] = []
        // Another thread reaching into the handle would wait on a held lock.
        player.duringSnapshot = { [weak lens] in
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = lens?.session
                done.signal()
            }
            free.append(done.wait(timeout: .now() + 1) == .success)
        }
        player.load(Self.source)
        player.play()
        lens.emitCustom("probe")
        XCTAssertFalse(free.isEmpty)
        XCTAssertTrue(free.allSatisfy { $0 })
    }

    #if canImport(UIKit)
        func testTheAppLifecycleNotificationsReportBAndBg() throws {
            Lens.appHidden = { false }
            let player = FakePlayer()
            _ = try playing(player)
            NotificationCenter.default.post(
                name: UIApplication.didEnterBackgroundNotification, object: nil)
            NotificationCenter.default.post(
                name: UIApplication.willEnterForegroundNotification, object: nil)
            XCTAssertEqual(delivered.map(\.type), ["b", "b"])
            XCTAssertEqual(delivered.map { status($0)["bg"] }, [.flag(true), nil])
        }
    #endif

    // MARK: capabilities

    private func probes(
        dolbyVision: Bool? = true, audio: [String]? = ["ac-3", "ec-3", "ac-4"]
    ) -> Capabilities.Probes {
        Capabilities.Probes(
            dolbyVision: { dolbyVision },
            audioDecoder: { codec in audio.map { $0.contains(codec) } })
    }

    func testListsTheDolbyDecodersThePlatformClaimsWithJocWhereverEac3Decodes() {
        XCTAssertEqual(
            Capabilities.probe(probes()),
            LensPlayerCapabilities(
                dolbyVision: true, dolbyAudioCodecs: ["ac-3", "ec-3", "ec-3-joc", "ac-4"]))
        XCTAssertEqual(
            Capabilities.probe(probes(audio: ["ac-3"])),
            LensPlayerCapabilities(dolbyVision: true, dolbyAudioCodecs: ["ac-3"]))
    }

    func testACompletedProbeThatFindsNothingIsAnEmptyListNotUnknown() {
        XCTAssertEqual(
            Capabilities.probe(probes(dolbyVision: false, audio: [])),
            LensPlayerCapabilities(dolbyVision: false, dolbyAudioCodecs: []))
    }

    func testLeavesAClaimOutWhenItsProbeCannotTellNeverPartial() {
        let unknownAc4 = Capabilities.Probes(
            dolbyVision: { nil }, audioDecoder: { $0 == "ac-4" ? nil : true })
        XCTAssertEqual(Capabilities.probe(unknownAc4), LensPlayerCapabilities())
    }

    func testIsDetectedOncePerProcess() {
        var calls = 0
        Capabilities.setProbesForTesting(
            Capabilities.Probes(
                dolbyVision: {
                    calls += 1
                    return true
                }, audioDecoder: { _ in true }))
        let first = Capabilities.platform()
        XCTAssertEqual(Capabilities.platform(), first)
        XCTAssertEqual(calls, 1)
    }

    func testThePlatformProbesAnswerInReportingOrder() {
        let detected = Capabilities.platform()
        let order = ["ac-3", "ec-3", "ec-3-joc", "ac-4"]
        let codecs = detected.dolbyAudioCodecs ?? []
        XCTAssertEqual(codecs, order.filter(codecs.contains))
        XCTAssertEqual(codecs.contains("ec-3"), codecs.contains("ec-3-joc"))
    }

    func testTheAdapterOverridesTheDetectedClaimsFieldByField() {
        Capabilities.setProbesForTesting(probes(audio: ["ac-3", "ec-3"]))
        let playback = Playback(now: { 0 })
        XCTAssertEqual(
            playback.capabilities(),
            LensPlayerCapabilities(
                dolbyVision: true, dolbyAudioCodecs: ["ac-3", "ec-3", "ec-3-joc"]))
        playback.observe(
            LensPlayerSnapshot(
                currentTime: 0, paused: true, ended: false,
                capabilities: LensPlayerCapabilities(dolbyVision: false)))
        XCTAssertEqual(
            playback.capabilities(),
            LensPlayerCapabilities(
                dolbyVision: false, dolbyAudioCodecs: ["ac-3", "ec-3", "ec-3-joc"]))
        playback.observe(
            LensPlayerSnapshot(
                currentTime: 0, paused: true, ended: false,
                capabilities: LensPlayerCapabilities(dolbyAudioCodecs: [])))
        XCTAssertEqual(
            playback.capabilities(), LensPlayerCapabilities(dolbyVision: true, dolbyAudioCodecs: [])
        )
    }
}
