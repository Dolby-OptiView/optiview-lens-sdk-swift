import Foundation

@testable import LensSDK

#if canImport(CoreFoundation)
    import CoreFoundation
#endif

/// A scripted player adapter: tests set its snapshot values and properties
/// and fire facts. `change` fires the complete properties, as the contract
/// asks. It records where Lens read it from, so tests can hold Lens to the
/// main queue.
final class FakePlayer: LensPlayerAdapter {
    /// The player this adapter stands for; itself unless a test shares one between adapters.
    var target: AnyObject { explicitTarget ?? self }
    private let explicitTarget: AnyObject?
    let playerName = "fake"
    var snapshotValues = LensPlayerSnapshot(currentTime: 0, paused: true, ended: false)
    var properties = LensPlayerProperties()
    var source: LensPlayerSource?
    private(set) var subscribeCalls = 0
    /// One entry per `snapshot()` call: whether it ran on the main thread.
    private(set) var snapshotReads: [Bool] = []
    private(set) var subscribedOnMain: [Bool] = []
    private(set) var releasedOnMain: [Bool] = []

    private var listeners: [(id: Int, listener: (LensPlayerFact) -> Void)] = []
    private var nextId = 0

    init(target: AnyObject? = nil) {
        explicitTarget = target
    }

    func subscribe(_ listener: @escaping (LensPlayerFact) -> Void) -> () -> Void {
        subscribeCalls += 1
        subscribedOnMain.append(Thread.isMainThread)
        let id = nextId
        nextId += 1
        listeners.append((id, listener))
        listener(.initial(source: source, properties: properties))
        return { [weak self] in
            self?.releasedOnMain.append(Thread.isMainThread)
            self?.listeners.removeAll { $0.id == id }
        }
    }

    /// Runs inside every `snapshot()` call, for tests that probe what Lens holds meanwhile.
    var duringSnapshot: (() -> Void)?

    func snapshot() -> LensPlayerSnapshot {
        snapshotReads.append(Thread.isMainThread)
        duringSnapshot?()
        return snapshotValues
    }

    var listenerCount: Int { listeners.count }

    func set(_ update: (inout LensPlayerSnapshot) -> Void) {
        update(&snapshotValues)
    }

    func fire(_ fact: LensPlayerFact) {
        for entry in listeners { entry.listener(fact) }
    }

    func change(_ update: (inout LensPlayerProperties) -> Void) {
        update(&properties)
        fire(.change(properties))
    }

    func load(_ source: LensPlayerSource?, continuation: Bool = false) {
        self.source = source
        snapshotValues.currentTime = 0
        snapshotValues.ended = false
        fire(.source(source, properties: properties, continuation: continuation))
    }

    /// The common outcome sequence of starting playback.
    func play() {
        fire(.play)
        snapshotValues.paused = false
        fire(.playing)
    }
}

/// The fixture interpreter's `player*` steps: JSON as the web interpreter
/// hands it to its fake player, into the Swift contract. A key present in a
/// step replaces the value, as `Object.assign` does.
enum PlayerFixture {
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        return number.doubleValue
    }

    static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBool(number) else { return nil }
        return number.boolValue
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func ranges(_ value: Any?) -> [LensTimeRange]? {
        (value as? [[String: Any]])?.map {
            LensTimeRange(start: number($0["start"]) ?? .nan, end: number($0["end"]) ?? .nan)
        }
    }

    static func buffered(_ value: Any?) -> [LensBufferedRanges]? {
        (value as? [[String: Any]])?.map {
            LensBufferedRanges(
                kind: ($0["kind"] as? String).flatMap(LensTrackKind.init(rawValue:)),
                ranges: ranges($0["ranges"]) ?? [])
        }
    }

    static func tracks(_ value: Any?) -> [LensTrack]? {
        (value as? [[String: Any]])?.map { track in
            LensTrack(
                id: track["id"] as! String,
                kind: LensTrackKind(rawValue: track["kind"] as! String)!,
                selected: flag(track["selected"]) ?? false,
                language: track["language"] as? String,
                label: track["label"] as? String,
                renditions: (track["renditions"] as? [[String: Any]])?.map { rendition in
                    LensRendition(
                        id: rendition["id"] as! String,
                        bitrate: number(rendition["bitrate"])!,
                        averageBitrate: number(rendition["averageBitrate"]),
                        combinedBitrate: flag(rendition["combinedBitrate"]),
                        codecs: rendition["codecs"] as? String,
                        width: number(rendition["width"]).map { Int($0) },
                        height: number(rendition["height"]).map { Int($0) },
                        frameRate: number(rendition["frameRate"]),
                        videoRange: (rendition["videoRange"] as? String)
                            .flatMap(LensVideoRange.init(rawValue:)),
                        channels: number(rendition["channels"]).map { Int($0) })
                },
                partialLadder: flag(track["partialLadder"]),
                loadingRenditionId: track["loadingRenditionId"] as? String,
                renderedRenditionId: track["renderedRenditionId"] as? String)
        }
    }

    static func source(_ value: Any?) -> LensPlayerSource? {
        guard let raw = value as? [String: Any] else { return nil }
        return LensPlayerSource(
            url: raw["url"] as? String,
            contentId: raw["contentId"] as? String,
            mimeType: raw["mimeType"] as? String,
            autoplay: flag(raw["autoplay"]),
            preload: (raw["preload"] as? String).flatMap(LensPreload.init(rawValue:)))
    }

    static func apply(snapshot values: [String: Any], to snapshot: inout LensPlayerSnapshot) {
        for (key, value) in values {
            switch key {
            case "currentTime": snapshot.currentTime = number(value) ?? .nan
            case "paused": snapshot.paused = flag(value) ?? false
            case "ended": snapshot.ended = flag(value) ?? false
            case "playheadDateTime":
                snapshot.playheadDateTime = number(value).map {
                    Date(timeIntervalSince1970: $0 / 1000)
                }
            case "duration": snapshot.duration = number(value)
            case "seekable": snapshot.seekable = ranges(value)
            case "buffered": snapshot.buffered = buffered(value)
            case "measuredThroughput": snapshot.measuredThroughput = number(value)
            case "droppedFrames": snapshot.droppedFrames = number(value).map { Int($0) }
            case "viewWidth": snapshot.viewWidth = number(value)
            case "viewHeight": snapshot.viewHeight = number(value)
            default: fatalError("unknown snapshot value \(key)")
            }
        }
    }

    static func apply(properties values: [String: Any], to properties: inout LensPlayerProperties) {
        for (key, value) in values {
            switch key {
            case "live": properties.live = flag(value)
            case "lowLatency": properties.lowLatency = flag(value)
            case "tracks": properties.tracks = tracks(value)
            case "targetBuffer": properties.targetBuffer = number(value)
            case "bufferStable": properties.bufferStable = flag(value)
            case "hasMediaData": properties.hasMediaData = flag(value)
            case "playbackRate": properties.playbackRate = number(value)
            case "muted": properties.muted = flag(value)
            case "volume": properties.volume = number(value)
            case "visibility":
                properties.visibility = (value as? String).flatMap(
                    LensViewVisibility.init(rawValue:))
            case "presentationMode":
                properties.presentationMode =
                    (value as? String).flatMap(LensPresentationMode.init(rawValue:))
            case "nonRendered": properties.nonRendered = flag(value)
            default: fatalError("unknown property \(key)")
            }
        }
    }

    static func fact(_ raw: [String: Any]) -> LensPlayerFact {
        switch raw["type"] as! String {
        case "play": return .play
        case "playing": return .playing
        case "pause": return .pause
        case "waiting": return .waiting
        case "seeking": return .seeking
        case "seeked": return .seeked
        case "ended": return .ended
        case "waitingForInput": return .waitingForInput
        case "error":
            return .error(
                fatal: flag(raw["fatal"]) ?? false, code: raw["code"] as! String,
                message: raw["message"] as? String)
        case let type: fatalError("unknown fact \(type)")
        }
    }
}
