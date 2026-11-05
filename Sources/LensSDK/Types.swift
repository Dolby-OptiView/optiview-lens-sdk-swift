import Foundation

public enum LensBackend: Equatable {
    case production
    case disabled
}

/// The backend actually in effect: the public options plus the dev product's.
internal enum EffectiveBackend: Equatable {
    case production
    case development
    case disabled
}

public struct LensConfigureOptions {
    public var backend: LensBackend
    /// Automatic flushing when the app leaves the foreground, on by default.
    /// Turn off only when the host flushes from its own lifecycle via
    /// `LensHandle.flush()`. Each `configure` applies it anew; omitting it
    /// restores the default.
    public var lifecycleFlush: Bool

    public init(backend: LensBackend, lifecycleFlush: Bool = true) {
        self.backend = backend
        self.lifecycleFlush = lifecycleFlush
    }
}

/// Join once per integrator instance, at boot: who I am (namespace) and where
/// my events go (destinations). Viewing sessions then start and end through
/// the handle — there is no re-join between sessions.
public struct LensJoinOptions {
    /// The integrator's product identity ("ads", "live", …), NOT a session
    /// concept: the same namespace spans every session of this handle. Bound at
    /// join so no product can emit as another; destination filters key on it.
    public var namespace: String
    public var destinations: [LensDestination]
    /// Optional — `.granted` by default; integrators that don't need a consent gate can ignore it.
    public var consent: LensConsent
    /// Emit-path violations (bad custom key or event names) hit a
    /// precondition when true — for development and CI builds. Default
    /// false: the offending key or event is dropped with a printed warning,
    /// and playback is never at risk. Setup problems (join/startSession
    /// arguments) always fail.
    public var strict: Bool
    /// Cadence of the session's liveness report (CMCD `e=t`), which Lens sends
    /// on its own — integrators never report it. Spec default 30000 ms; 0 turns
    /// it off; otherwise at least 1000 ms.
    public var heartbeatMs: Int64
    /// Delivery hints for this handle's built-in OptiView ingest queue,
    /// including heartbeats. Use `destinations[].batch` for extra destinations.
    /// By default, each event is sent immediately. Ignored when the backend is
    /// disabled. With `maxEvents` and no `maxDelayMs`, events wait until the
    /// count is reached or the queue flushes on session end, dispose, or
    /// lifecycle flush.
    public var batch: LensBatch?
    /// The player this handle observes, through its adapter — compared by
    /// identity, so wrap a player once and hand the same adapter to every SDK.
    /// Lens then owns the session: it watches the player, reports playback
    /// state and the player's CMCD keys, and starts a session at the first
    /// play request on each source and ends it itself.
    /// Handles naming the same adapter share that session. Without one, the
    /// handle runs its own sessions through `startSession`/`endSession`.
    public var player: (any LensPlayerAdapter)?

    public init(
        namespace: String,
        destinations: [LensDestination] = [],
        consent: LensConsent = .granted,
        strict: Bool = false,
        heartbeatMs: Int64 = 30_000,
        player: (any LensPlayerAdapter)? = nil,
        batch: LensBatch? = nil
    ) {
        self.namespace = namespace
        self.destinations = destinations
        self.consent = consent
        self.strict = strict
        self.heartbeatMs = heartbeatMs
        self.player = player
        self.batch = batch
    }
}

public struct LensSourceChange {
    /// Whether the change starts a new viewing session (fresh sid) or
    /// continues the current one (same sid and sequence, `c`/`h` change events).
    public var newSession: Bool
    /// The new main content ID (1-128 printable ASCII).
    public var contentId: String?
    /// The new delivery hostname (spec `h`, 1-128 printable ASCII).
    public var hostname: String?
    /// The new streaming format (`sf`): "d", "h", "s", "e", "o".
    public var streamingFormat: String?

    public init(
        newSession: Bool,
        contentId: String? = nil,
        hostname: String? = nil,
        streamingFormat: String? = nil
    ) {
        self.newSession = newSession
        self.contentId = contentId
        self.hostname = hostname
        self.streamingFormat = streamingFormat
    }
}

public protocol LensHandle: AnyObject {
    /// Temporary session-control door for handles joined without a `player`:
    /// the integrator tells Lens when a viewing session starts. Starting while
    /// one is active rolls it (new sid). With a `player`, Lens owns the session
    /// and this warns and returns the current one — or, between sessions, a
    /// placeholder no report carries, as a disposed handle does; read `session`
    /// instead.
    @discardableResult
    func startSession(_ options: LensStartSessionOptions) -> LensSession
    /// Ends this handle's session; with a `player`, warns and does nothing.
    func endSession()
    /// The active session, or nil between sessions.
    var session: LensSession? { get }
    /// Report that the playback source changed, for handles without a
    /// `player`; with one, Lens observes the source and this warns.
    /// `newSession: false` keeps the session — the sid survives, the context
    /// updates, and the spec's own change events (`c`, `h`) fire only for what
    /// actually changed. `newSession: true` rotates the sid, exactly like
    /// starting over. Never implement a same-session change as `endSession()`
    /// + `startSession()`: that splits the session and resets `sn` — the one
    /// thing it must not do.
    func reportSourceChange(_ change: LensSourceChange)
    /// Report a standard CMCD event. The payload type follows the token:
    /// free-form events take `LensPayload`; spec-shaped events get
    /// compile-checked typed payloads. Dropped when consent is denied, or when
    /// no session is active — on a handle joined with a `player`, held instead
    /// until playback starts one. Registered CMCD names inside `custom` hit a
    /// fatal precondition.
    func emit<P: LensEventPayload>(_ type: LensEventType<P>, payload: P?)
    /// Report a custom event — anything the spec has no type for. Lowered to the
    /// CMCD custom event ("ce") with `name` as the custom event name ("cen") on
    /// the wire, unqualified per spec and in-core precedent. `name` must be a
    /// simple token (letters, digits, '-', '_'); otherwise the event is dropped.
    /// Takes the same `LensPayload` shape as free-form standard events.
    func emitCustom(_ name: String, payload: LensPayload?)
    /// Attach this integrator's current state to the session's liveness
    /// reports: every heartbeat from now on carries these keys, in this
    /// handle's namespace either way — keys come and go, the namespace does
    /// not. Latest call wins; nil (or nothing valid left) goes back to a plain
    /// liveness report. Sets state only — it never sends and never shifts the
    /// cadence. The payload's top level is Lens's; `custom` is yours.
    func setHeartbeatPayload(_ payload: LensPayload?)
    /// Change the liveness cadence on a live handle — faster during an ad
    /// break, slower in the background. Same rule as `heartbeatMs` at join:
    /// `0` is off, anything else is at least 1000 milliseconds. A new cadence
    /// opens with a report and runs from there, the way a session's does; `0`
    /// stops without one, and re-setting the interval already in force does
    /// nothing.
    func setHeartbeatInterval(_ ms: Int64)
    func setConsent(_ consent: LensConsent)
    /// Send everything pending now. Not needed by a standard integrator —
    /// lifecycle flushing already covers the common cliffs; this is for hosts
    /// that opted out of it or live outside the observed lifecycles. Does not
    /// end the session; no-op after dispose.
    func flush()
    func dispose()
}

extension LensHandle {
    @discardableResult
    public func startSession() -> LensSession {
        startSession(LensStartSessionOptions())
    }

    public func emit<P: LensEventPayload>(_ type: LensEventType<P>) {
        emit(type, payload: nil)
    }

    public func emitCustom(_ name: String) {
        emitCustom(name, payload: nil)
    }

    public func setHeartbeatPayload() {
        setHeartbeatPayload(nil)
    }
}

/// The payload contract: custom keys always live under `custom`, so a future
/// spec revision adding typed fields to any event is additive — never a
/// call-site break. Typed events conform with their spec fields alongside.
public protocol LensEventPayload {
    var custom: LensEventKeys? { get }
}

/// The one free-form payload shape (all v0 ad events, and `emitCustom`).
public struct LensPayload: LensEventPayload {
    /// Custom keys — short names; registered CMCD names fail at emit.
    public let custom: LensEventKeys?

    public init(custom: LensEventKeys? = nil) {
        self.custom = custom
    }
}

/// Payload for the ad events that carry content identity (CTA-5004-B §8.2.8):
/// `adStart` swaps the session's `cid` for the ad's until the ad or its break
/// ends; `adEnd`/`adSkip` may carry it to label themselves when arriving out
/// of order — they never re-open a swap. Content-replacing break formats
/// only: overlays are not an ad for `cid` purposes and must not feed this
/// field.
public struct LensAdPayload: LensEventPayload {
    /// The ad's own content ID (1-128 printable ASCII), reported as `cid`.
    public let contentId: String?
    public let custom: LensEventKeys?

    public init(contentId: String? = nil, custom: LensEventKeys? = nil) {
        self.contentId = contentId
        self.custom = custom
    }
}

/// A standard CMCD (CTA-5004-B) event type token, carrying the payload type
/// it accepts — grows additively as more of the spec is adopted. v0 carries
/// the ad set (`LensPayload`, with `LensAdPayload` on the ad-identity
/// events); anything not listed here goes
/// through `emitCustom`. Wire codes are the spec values.
public struct LensEventType<Payload: LensEventPayload> {
    public let wireCode: String

    internal init(_ wireCode: String) {
        self.wireCode = wireCode
    }
}

extension LensEventType where Payload == LensPayload {
    /// An ad break has started (wire: "abs").
    public static var adBreakStart: LensEventType<LensPayload> { .init("abs") }
    /// An ad break has ended (wire: "abe").
    public static var adBreakEnd: LensEventType<LensPayload> { .init("abe") }
}

extension LensEventType where Payload == LensAdPayload {
    /// An ad has started playing (wire: "as").
    public static var adStart: LensEventType<LensAdPayload> { .init("as") }
    /// An ad has ended (wire: "ae").
    public static var adEnd: LensEventType<LensAdPayload> { .init("ae") }
    /// An ad was skipped (wire: "sk").
    public static var adSkip: LensEventType<LensAdPayload> { .init("sk") }
}

/// Swift cannot reflect over the static token extensions above, so the
/// vocabulary conformance test reads this list instead. Keep it in step with
/// the declarations; the cross-platform vocabulary names are the map keys.
internal enum LensEventVocabulary {
    static let declaredTokens: [String: String] = [
        "AD_BREAK_START": LensEventType<LensPayload>.adBreakStart.wireCode,
        "AD_START": LensEventType<LensAdPayload>.adStart.wireCode,
        "AD_END": LensEventType<LensAdPayload>.adEnd.wireCode,
        "AD_BREAK_END": LensEventType<LensPayload>.adBreakEnd.wireCode,
        "AD_SKIP": LensEventType<LensAdPayload>.adSkip.wireCode,
    ]
}

/// Marks a custom value that must be emitted as an unquoted structured-field
/// token. The marker avoids inferring token-ness from ordinary enum strings.
public struct LensToken {
    public let value: String

    public init(value: String) {
        self.value = value
    }
}

/// Event payload custom keys — CMCD value types (String, Number, Bool,
/// LensToken). Short names everywhere the integrator and the backend look; the
/// CMCD wire hop alone qualifies them with the reverse-DNS prefix (a transport
/// artifact, stripped again on ingest). Registered CMCD key names fail at
/// emit; invalid token values are dropped.
public typealias LensEventKeys = [String: Any]

public struct LensStartSessionOptions {
    /// Externally steered session id (e.g. injected by discovery); Lens generates a UUID when absent.
    public var sessionId: String?
    /// The main content's ID (1-128 printable ASCII), stamped as `cid` on every report of the session.
    public var contentId: String?
    /// Streaming format (`sf`): "d" DASH, "h" HLS, "s" Smooth, "e" HESP, "o" other.
    public var streamingFormat: String?
    /// Stream type (`st`): "v" VOD, "l" live, "ll" low-latency live.
    public var streamType: String?

    public init(
        sessionId: String? = nil,
        contentId: String? = nil,
        streamingFormat: String? = nil,
        streamType: String? = nil
    ) {
        self.sessionId = sessionId
        self.contentId = contentId
        self.streamingFormat = streamingFormat
        self.streamType = streamType
    }
}

/// Where events get delivered. In CMCD v2 terms, a `.cmcd`-format destination
/// is an "event target"; `.json` destinations are a Lens extension beyond the spec.
public struct LensDestination {
    public var url: String
    public var filter: LensDestinationFilter?
    /// Wire format for this destination: `.cmcd` (default) — CMCD key
    /// serialization posted as application/cmcd, for CMCD-aware receivers like
    /// the OptiView ingest; `.json` — the same canonical report JSON-encoded,
    /// posted as application/json, for endpoints that don't parse CMCD
    /// (customer ad-ops hooks). Formats change encoding, never vocabulary.
    public var format: LensFormat
    /// Delivery hints, consumed by the transport: flush at maxEvents pending, or when the oldest event has waited maxDelayMs (0 = per event).
    public var batch: LensBatch?
    /// Whether this destination receives the SDK's liveness reports (`e=t`).
    /// Defaults to true for `.cmcd` — a CMCD event target is what the heartbeat
    /// is specified for — and false for every other format, so receivers only
    /// get liveness traffic they asked for.
    public var heartbeat: Bool?

    public init(
        url: String,
        filter: LensDestinationFilter? = nil,
        format: LensFormat = .cmcd,
        batch: LensBatch? = nil,
        heartbeat: Bool? = nil
    ) {
        self.url = url
        self.filter = filter
        self.heartbeat = heartbeat
        self.format = format
        self.batch = batch
    }
}

public struct LensDestinationFilter {
    public var namespaces: [String]?
    /// Matches the event's wire type — or the custom name for custom events.
    public var events: [String]?

    public init(namespaces: [String]? = nil, events: [String]? = nil) {
        self.namespaces = namespaces
        self.events = events
    }
}

/// Delivery hints, consumed by the transport: flush at maxEvents pending, or when the oldest event has waited maxDelayMs (0 = per event).
public struct LensBatch {
    public var maxEvents: Int?
    public var maxDelayMs: Int64?

    public init(maxEvents: Int? = nil, maxDelayMs: Int64? = nil) {
        self.maxEvents = maxEvents
        self.maxDelayMs = maxDelayMs
    }
}

public enum LensFormat {
    case cmcd
    case json
}

public enum LensConsent {
    case granted
    case denied
}

public struct LensSession {
    public let sessionId: String

    internal init(sessionId: String) {
        self.sessionId = sessionId
    }
}

/// Wire-side only — what destinations receive. Integrators never construct it.
public struct LensEvent {
    /// The spec wire code ("abs", "as", …) — or "ce" for custom events.
    public let type: String
    /// The custom event name (spec "cen"); present only when `type` is "ce".
    public let customName: String?
    public let namespace: String
    public let keys: LensEventKeys?
    /// Epoch milliseconds.
    public let timestamp: Int64
    public let session: LensSession
    /// The effective content ID (`cid`) at emit time — the ad's during a swap, the session's otherwise.
    public let contentId: String?
    /// Streaming format (`sf`), from the session.
    public let streamingFormat: String?
    /// Stream type (`st`), from the session.
    public let streamType: String?
    /// The serving hostname (spec `h`), on hostname-change events and every report of a player session.
    public let hostname: String?
    /// Playback state (spec `sta`); Lens-owned — the quit report and the reports of a player session carry it.
    public let playbackState: String?
    /// The other CMCD keys Lens reads from the player adapter or derives from its facts.
    internal let status: StatusKeys?

    internal init(
        type: String, customName: String?, namespace: String, keys: LensEventKeys?,
        timestamp: Int64, session: LensSession,
        contentId: String? = nil, streamingFormat: String? = nil, streamType: String? = nil,
        hostname: String? = nil, playbackState: String? = nil, status: StatusKeys? = nil
    ) {
        self.type = type
        self.customName = customName
        self.namespace = namespace
        self.keys = keys
        self.timestamp = timestamp
        self.session = session
        self.contentId = contentId
        self.streamingFormat = streamingFormat
        self.streamType = streamType
        self.hostname = hostname
        self.playbackState = playbackState
        self.status = status
    }
}

public enum LensError: Error, Equatable {
    case invalidOptions(String)
}

/// A CMCD inner-list member: one value per object type (`ot`), or a single value without one.
internal struct InnerListItem: Equatable {
    let value: Double
    let ot: String?

    init(_ value: Double, ot: String? = nil) {
        self.value = value
        self.ot = ot
    }
}

/// A registered CMCD key's value, as reported.
internal enum StatusValue: Equatable {
    case number(Double)
    case flag(Bool)
    case list([InnerListItem])
    case strings([String])
}

/// Registered CMCD keys and their values, kept in the order they were first
/// set — the order a JSON destination sees, as on web.
internal struct StatusKeys: Equatable {
    private(set) var entries: [(key: String, value: StatusValue)] = []

    var isEmpty: Bool { entries.isEmpty }

    subscript(key: String) -> StatusValue? {
        get { entries.first { $0.key == key }?.value }
        set {
            let index = entries.firstIndex { $0.key == key }
            switch (index, newValue) {
            case (let index?, let value?): entries[index].value = value
            case (let index?, nil): entries.remove(at: index)
            case (nil, let value?): entries.append((key, value))
            case (nil, nil): break
            }
        }
    }

    subscript(key: CmcdKey) -> StatusValue? {
        get { self[key.rawValue] }
        set { self[key.rawValue] = newValue }
    }

    /// `other`'s keys win; a key already here keeps its place.
    mutating func merge(_ other: StatusKeys) {
        for (key, value) in other.entries { self[key] = value }
    }

    static func == (lhs: StatusKeys, rhs: StatusKeys) -> Bool {
        lhs.entries.map(\.key) == rhs.entries.map(\.key)
            && lhs.entries.map(\.value) == rhs.entries.map(\.value)
    }
}
