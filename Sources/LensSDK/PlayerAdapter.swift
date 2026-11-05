import Foundation

/// What a player tells Lens. The adapter reports the player's own model —
/// time ranges, tracks, counters, settings — never CMCD values: Lens owns
/// every interpretation, so the reported vocabulary can grow without
/// adapter changes.
///
/// Values whose change Lens reports — a bitrate switch, mute, rate,
/// visibility, presentation mode, the stream type, the buffer turning
/// stable — are pushed, whole, with the fact that changes them, so no
/// transition is missed or seen late. Values Lens only samples into a report
/// are read through `snapshot()` when it reports.
///
/// Threading: Lens calls the adapter on the main queue only, and facts must
/// be delivered there, in the order they happened, so Lens reads a fact's
/// snapshot where it receives the fact. Lens moves its own reads (heartbeats,
/// integrator events) to the main queue. A fact fired from inside
/// `snapshot()` is handled after the work in progress, not in the middle of
/// it.
///
/// A class, because Lens tells players apart by identity: wrap a player once
/// and hand the same adapter to every SDK.
///
/// Every optional field: leave it nil while unknown, never a placeholder.
public protocol LensPlayerAdapter: AnyObject {
    /// The player product, e.g. `AVPlayer` or `THEOplayer`, as its maker names it.
    var playerName: String { get }
    /// The player's version as it reports it, build suffixes included.
    var playerVersion: String? { get }
    /// Lens's one subscription, until the returned closure is called. The
    /// first fact delivered must be `initial`, with the player's current state.
    func subscribe(_ listener: @escaping (LensPlayerFact) -> Void) -> () -> Void
    /// The sampled values as they are now; cheap.
    func snapshot() -> LensPlayerSnapshot
}

extension LensPlayerAdapter {
    public var playerVersion: String? { nil }
}

/// The values Lens samples into a report, as they are at one moment.
public struct LensPlayerSnapshot: Sendable, Equatable {
    /// Playhead position.
    public var currentTime: TimeInterval
    /// Whether the player is paused, by the user or by itself; false while playing or stalled.
    public var paused: Bool
    /// Whether the playhead has reached the end of the media.
    public var ended: Bool
    /// The date of the frame at the playhead, when the stream has a program date time.
    public var playheadDateTime: Date?
    /// The media's length; `.infinity` for a live stream without an end.
    public var duration: TimeInterval?
    /// The ranges the player can seek to — on a live stream, up to the live edge.
    public var seekable: [LensTimeRange]?
    /// What is buffered: per track kind where the player can tell, else one entry without `kind`.
    public var buffered: [LensBufferedRanges]?
    /// The throughput estimate the ABR logic decides on, bits per second.
    public var measuredThroughput: Double?
    /// The decoder's dropped-frame counter as the player keeps it, cumulative;
    /// Lens counts from the session start. Lens sees a reset only when the
    /// counter drops between two reads, so a player that swaps decoders
    /// should keep counting across the swap.
    public var droppedFrames: Int?
    /// The size of the player's view on screen, in points — not the video's.
    public var viewWidth: Double?
    public var viewHeight: Double?
    /// Overrides, field by field, the capabilities Lens detects on the device
    /// itself. Only for a player that knows better, e.g. one that cannot use a
    /// codec the device can decode; leave it nil otherwise.
    public var capabilities: LensPlayerCapabilities?

    public init(
        currentTime: TimeInterval,
        paused: Bool,
        ended: Bool,
        playheadDateTime: Date? = nil,
        duration: TimeInterval? = nil,
        seekable: [LensTimeRange]? = nil,
        buffered: [LensBufferedRanges]? = nil,
        measuredThroughput: Double? = nil,
        droppedFrames: Int? = nil,
        viewWidth: Double? = nil,
        viewHeight: Double? = nil,
        capabilities: LensPlayerCapabilities? = nil
    ) {
        self.currentTime = currentTime
        self.paused = paused
        self.ended = ended
        self.playheadDateTime = playheadDateTime
        self.duration = duration
        self.seekable = seekable
        self.buffered = buffered
        self.measuredThroughput = measuredThroughput
        self.droppedFrames = droppedFrames
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.capabilities = capabilities
    }
}

/// What the player can do on this device, whatever is playing — not what it
/// is doing now. Today: which Dolby formats it can decode, without DRM.
public struct LensPlayerCapabilities: Sendable, Equatable {
    /// Whether Dolby Vision can be decoded here; says nothing about what is playing.
    public var dolbyVision: Bool?
    /// The Dolby audio codecs that can be decoded here, whatever is playing,
    /// in this order: `ac-3`, `ec-3`, `ec-3-joc` (E-AC-3 JOC, Atmos), `ac-4`.
    /// Empty when none can.
    public var dolbyAudioCodecs: [String]?

    public init(dolbyVision: Bool? = nil, dolbyAudioCodecs: [String]? = nil) {
        self.dolbyVision = dolbyVision
        self.dolbyAudioCodecs = dolbyAudioCodecs
    }
}

/// The time ranges the player holds in its buffer.
public struct LensBufferedRanges: Sendable, Equatable {
    /// The media these ranges hold; nil when the player buffers all media together.
    public var kind: LensTrackKind?
    public var ranges: [LensTimeRange]

    public init(kind: LensTrackKind? = nil, ranges: [LensTimeRange]) {
        self.kind = kind
        self.ranges = ranges
    }
}

/// As the player reports them.
public struct LensTimeRange: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval

    public init(start: TimeInterval, end: TimeInterval) {
        self.start = start
        self.end = end
    }
}

/// The values whose change Lens reports; pushed whole in `initial`, `source` and every `change`.
public struct LensPlayerProperties: Sendable, Equatable {
    /// Whether the stream gains segments over time (live, its DVR window included); false when all are there (VOD).
    public var live: Bool?
    /// Whether the stream is low-latency live (LL-HLS parts, LL-DASH chunks)
    /// and the player loads it that way. A property of the stream, not of the
    /// playhead: playing behind the live edge keeps it true.
    public var lowLatency: Bool?
    /// Every track the source offers, selected or not.
    public var tracks: [LensTrack]?
    /// The buffer level the player aims for.
    public var targetBuffer: TimeInterval?
    /// Whether the player expects to play on without stalling — on AVFoundation,
    /// `isPlaybackLikelyToKeepUp`. Push a `change` whenever it flips: the first
    /// time it turns true ends `su`.
    public var bufferStable: Bool?
    /// Whether the player holds media data for the source, beyond its metadata
    /// — on AVPlayer, a non-empty `loadedTimeRanges`. Push a `change` whenever
    /// it flips: media held before playback is requested is preloading
    /// (`sta=d`), whatever the player's preload setting says.
    public var hasMediaData: Bool?
    /// The speed the player is set to, 1 for real time. While paused, still the setting, not 0.
    public var playbackRate: Double?
    /// Whether the player is muted; Lens also counts `volume` 0 as muted.
    public var muted: Bool?
    /// The player's volume, 0 to 1.
    public var volume: Double?
    /// Whether the player's own view can be seen: `.hidden` when the user
    /// scrolled it out of view or covered it. Lens observes the app itself,
    /// so leave this nil unless the player knows its view.
    public var visibility: LensViewVisibility?
    /// How the player is shown: picture-in-picture, inline, or fullscreen.
    public var presentationMode: LensPresentationMode?
    /// Whether the player loads content it does not render, such as a background player.
    public var nonRendered: Bool?

    public init(
        live: Bool? = nil,
        lowLatency: Bool? = nil,
        tracks: [LensTrack]? = nil,
        targetBuffer: TimeInterval? = nil,
        bufferStable: Bool? = nil,
        hasMediaData: Bool? = nil,
        playbackRate: Double? = nil,
        muted: Bool? = nil,
        volume: Double? = nil,
        visibility: LensViewVisibility? = nil,
        presentationMode: LensPresentationMode? = nil,
        nonRendered: Bool? = nil
    ) {
        self.live = live
        self.lowLatency = lowLatency
        self.tracks = tracks
        self.targetBuffer = targetBuffer
        self.bufferStable = bufferStable
        self.hasMediaData = hasMediaData
        self.playbackRate = playbackRate
        self.muted = muted
        self.volume = volume
        self.visibility = visibility
        self.presentationMode = presentationMode
        self.nonRendered = nonRendered
    }
}

/// The media the app gave the player.
public struct LensPlayerSource: Sendable, Equatable {
    /// The media URL as the app set it. Leave it nil for a source that has
    /// none, such as an SSAI stream named by asset IDs; `contentId` is then
    /// required.
    public var url: String?
    /// The service's content ID (1-128 printable ASCII); without it Lens derives one from `url`.
    public var contentId: String?
    /// The source's MIME type, e.g. `application/x-mpegurl`.
    public var mimeType: String?
    /// Whether the player starts playing on its own once the source loads.
    public var autoplay: Bool?
    /// The player's preload setting, as context only: whether the player
    /// preloads is read from what it loads (`hasMediaData`), since a setting
    /// can change later, be ignored, or not exist (AVPlayer has none).
    public var preload: LensPreload?

    public init(
        url: String? = nil,
        contentId: String? = nil,
        mimeType: String? = nil,
        autoplay: Bool? = nil,
        preload: LensPreload? = nil
    ) {
        self.url = url
        self.contentId = contentId
        self.mimeType = mimeType
        self.autoplay = autoplay
        self.preload = preload
    }
}

/// The player's preload setting; `off` is preloading nothing (`none` on web).
public enum LensPreload: String, Sendable, Equatable {
    case off = "none"
    case metadata
    case auto
}

/// `muxed`: audio and video in one stream, such as an HLS variant without separate audio.
public enum LensTrackKind: String, Sendable, Equatable {
    case video
    case audio
    case text
    case muxed
}

/// One track of the source, e.g. an audio language or the video.
public struct LensTrack: Sendable, Equatable {
    /// The player's own track identifier, stable while the source plays.
    public var id: String
    public var kind: LensTrackKind
    /// Whether the track is in use: the audio or video being played, the text track showing.
    public var selected: Bool
    /// BCP 47, as the manifest declares it.
    public var language: String?
    /// The display name, as the manifest declares it.
    public var label: String?
    /// The qualities the player can choose from, as far as it knows them.
    public var renditions: [LensRendition]?
    /// Whether `renditions` lists only some of the qualities, so it is not the full ladder.
    public var partialLadder: Bool?
    /// The rendition being fetched.
    public var loadingRenditionId: String?
    /// The rendition on screen or audible now.
    public var renderedRenditionId: String?

    public init(
        id: String,
        kind: LensTrackKind,
        selected: Bool,
        language: String? = nil,
        label: String? = nil,
        renditions: [LensRendition]? = nil,
        partialLadder: Bool? = nil,
        loadingRenditionId: String? = nil,
        renderedRenditionId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.selected = selected
        self.language = language
        self.label = label
        self.renditions = renditions
        self.partialLadder = partialLadder
        self.loadingRenditionId = loadingRenditionId
        self.renderedRenditionId = renderedRenditionId
    }
}

/// One quality of a track.
public struct LensRendition: Sendable, Equatable {
    /// The player's own identifier, unique within the track; `loadingRenditionId` and `renderedRenditionId` point at it.
    public var id: String
    /// Peak bitrate, bits per second.
    public var bitrate: Double
    /// Average bitrate, bits per second, when the manifest declares one.
    public var averageBitrate: Double?
    /// Whether `bitrate` counts every media type played with this rendition, as an HLS variant's BANDWIDTH does.
    public var combinedBitrate: Bool?
    /// RFC 6381 codecs, e.g. `dvh1.05.06` or `ec-3`; a comma-separated list when the rendition carries several media types.
    public var codecs: String?
    /// The encoded picture size in pixels — the rendition's, never the player's on screen.
    public var width: Int?
    public var height: Int?
    /// Frames per second.
    public var frameRate: Double?
    /// The dynamic range as the manifest declares it: standard, PQ (HDR10, Dolby Vision) or HLG.
    public var videoRange: LensVideoRange?
    /// Audio channel count.
    public var channels: Int?

    public init(
        id: String,
        bitrate: Double,
        averageBitrate: Double? = nil,
        combinedBitrate: Bool? = nil,
        codecs: String? = nil,
        width: Int? = nil,
        height: Int? = nil,
        frameRate: Double? = nil,
        videoRange: LensVideoRange? = nil,
        channels: Int? = nil
    ) {
        self.id = id
        self.bitrate = bitrate
        self.averageBitrate = averageBitrate
        self.combinedBitrate = combinedBitrate
        self.codecs = codecs
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoRange = videoRange
        self.channels = channels
    }
}

/// The dynamic range a rendition declares.
public enum LensVideoRange: String, Sendable, Equatable {
    case sdr
    case pq
    case hlg
}

/// Whether the player's own view can be seen.
public enum LensViewVisibility: String, Sendable, Equatable {
    case visible
    case hidden
}

/// Ordered by size: moving up reports `pe` (expand), moving down `pc` (collapse).
public enum LensPresentationMode: String, Sendable, Equatable {
    case pictureInPicture = "pip"
    case inline
    case fullscreen
}

/// What happened on the player.
public enum LensPlayerFact: Sendable, Equatable {
    /// The player's state when Lens subscribes — always the first fact.
    case initial(source: LensPlayerSource?, properties: LensPlayerProperties)
    /// A source was set, replaced (`nil`: removed). `properties` are as they
    /// are for the new source: what belongs to the old one (`live`, `tracks`,
    /// `bufferStable`, `hasMediaData`, …) starts over, so leave it nil until
    /// known. `continuation`: whether it continues the viewing session — a
    /// fallback to another URL of the same content.
    case source(LensPlayerSource?, properties: LensPlayerProperties, continuation: Bool = false)
    /// Properties changed; all of them are listed, so a value can also become unknown.
    case change(LensPlayerProperties)
    /// The app or the user asked the player to play.
    case play
    /// Frames are being rendered.
    case playing
    /// The user or the player paused.
    case pause
    /// Playback stalled for lack of data.
    case waiting
    /// A seek started.
    case seeking
    /// The seek finished; playback resumes, or stays paused, from the new position.
    case seeked
    /// Playback reached the end of the media.
    case ended
    /// `code` is reported as `ec`; `fatal`: whether playback cannot continue on
    /// this source. `message` is one line, including the platform's own error
    /// text (an `NSError` domain and code, an HTTP status).
    case error(fatal: Bool, code: String, message: String? = nil)
    /// The player cannot proceed without the user, e.g. playback needs a tap.
    case waitingForInput
}
