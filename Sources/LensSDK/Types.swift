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

    public init(backend: LensBackend) {
        self.backend = backend
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

    public init(
        namespace: String,
        destinations: [LensDestination] = [],
        consent: LensConsent = .granted,
        strict: Bool = false
    ) {
        self.namespace = namespace
        self.destinations = destinations
        self.consent = consent
        self.strict = strict
    }
}

public protocol LensHandle: AnyObject {
    /// Temporary session-control door: the integrator tells Lens when a viewing
    /// session starts/ends. Starting while one is active rolls it (new sid).
    /// The player-adapter phase will absorb this into automatic session management.
    @discardableResult
    func startSession(_ options: LensStartSessionOptions) -> LensSession
    func endSession()
    /// The active session, or nil between sessions.
    var session: LensSession? { get }
    /// Report a standard CMCD event. The payload type follows the token:
    /// free-form events take `LensPayload`; spec-shaped events get
    /// compile-checked typed payloads. Dropped when no session is active or
    /// consent is denied; registered CMCD names inside `custom` hit a
    /// fatal precondition.
    func emit<P: LensEventPayload>(_ type: LensEventType<P>, payload: P?)
    /// Report a custom event — anything the spec has no type for. Lowered to the
    /// CMCD custom event ("ce") with `name` as the custom event name ("cen") on
    /// the wire, unqualified per spec and in-core precedent. `name` must be a
    /// simple token (letters, digits, '-', '_'); otherwise the event is dropped.
    /// Takes the same `LensPayload` shape as free-form standard events.
    func emitCustom(_ name: String, payload: LensPayload?)
    func setConsent(_ consent: LensConsent)
    func dispose()
}

public extension LensHandle {
    @discardableResult
    func startSession() -> LensSession {
        startSession(LensStartSessionOptions())
    }

    func emit<P: LensEventPayload>(_ type: LensEventType<P>) {
        emit(type, payload: nil)
    }

    func emitCustom(_ name: String) {
        emitCustom(name, payload: nil)
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

/// A standard CMCD (CTA-5004-B) event type token, carrying the payload type
/// it accepts — grows additively as more of the spec is adopted. v0 carries
/// the ad set (all free-form: `LensPayload`); anything not listed here goes
/// through `emitCustom`. Wire codes are the spec values.
public struct LensEventType<Payload: LensEventPayload> {
    public let wireCode: String

    internal init(_ wireCode: String) {
        self.wireCode = wireCode
    }
}

public extension LensEventType where Payload == LensPayload {
    /// An ad break has started (wire: "abs").
    static var adBreakStart: LensEventType<LensPayload> { .init("abs") }
    /// An ad has started playing (wire: "as").
    static var adStart: LensEventType<LensPayload> { .init("as") }
    /// An ad has ended (wire: "ae").
    static var adEnd: LensEventType<LensPayload> { .init("ae") }
    /// An ad break has ended (wire: "abe").
    static var adBreakEnd: LensEventType<LensPayload> { .init("abe") }
    /// An ad was skipped (wire: "sk").
    static var adSkip: LensEventType<LensPayload> { .init("sk") }
}

/// Event payload custom keys — CMCD value types (String, Number, Bool) only,
/// so every key serializes cleanly. Short names everywhere the integrator and
/// the backend look; the CMCD wire hop alone qualifies them with the
/// reverse-DNS prefix (a transport artifact, stripped again on ingest).
/// Registered CMCD key names fail at emit; non-token names are dropped.
public typealias LensEventKeys = [String: Any]

public struct LensStartSessionOptions {
    /// Externally steered session id (e.g. injected by discovery); Lens generates a UUID when absent.
    public var sessionId: String?

    public init(sessionId: String? = nil) {
        self.sessionId = sessionId
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

    public init(url: String, filter: LensDestinationFilter? = nil, format: LensFormat = .cmcd, batch: LensBatch? = nil) {
        self.url = url
        self.filter = filter
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

    internal init(type: String, customName: String?, namespace: String, keys: LensEventKeys?, timestamp: Int64, session: LensSession) {
        self.type = type
        self.customName = customName
        self.namespace = namespace
        self.keys = keys
        self.timestamp = timestamp
        self.session = session
    }
}

public enum LensError: Error, Equatable {
    case invalidOptions(String)
}
