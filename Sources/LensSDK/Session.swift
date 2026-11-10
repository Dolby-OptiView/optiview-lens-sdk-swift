import Foundation

/// Sessions and who shares them: the binding of handles to one session, the
/// only code that starts, continues or ends one, and Lens's own reports on
/// it. Handles (Lens.swift) are the integrators' side; the player's side is
/// PlayerObserver.swift. Mechanics: docs/internals.md.

/// What a binding needs from each handle bound to it. Called under the binding's lock.
internal protocol SessionMember: AnyObject {
    /// A session started or rolled: restart the heartbeat.
    func sessionStarted()
    /// The session ended: stop the heartbeat, let pending posts go.
    func sessionEnded()
    func flushTransport()
    func hasConsent() -> Bool
    /// Adds this handle's latest heartbeat payload to a session-ending report's keys.
    func contributeSessionEndContext(_ keys: inout LensEventKeys)
    /// Hands a report to every destination that takes it; `heartbeat` marks the liveness stream.
    func deliver(_ event: LensEvent, heartbeat: Bool)
}

/// The session manager's state — the only place a sid is ever minted,
/// rotated, or ended. Sessions are internal objects, never public API:
/// integrators see only the read-only `LensSession` through `handle.session`.
internal final class SessionState {
    let session: LensSession
    var contentId: String?
    var streamingFormat: String?
    var streamType: String?
    var hostname: String?
    var quitSent = false

    init(context: SessionContext) {
        self.session = LensSession(sessionId: context.sessionId ?? Lens.sessionIdFactory())
        self.contentId = context.contentId
        self.streamingFormat = context.streamingFormat
        self.streamType = context.streamType
        self.hostname = context.hostname
    }
}

/// What a session is started or continued with.
internal struct SessionContext {
    var sessionId: String?
    var contentId: String?
    var streamingFormat: String?
    var streamType: String?
    var hostname: String?
}

/// What the player says at one moment, as Lens's reports and the
/// integrators' alike carry it: the state and its keys.
internal struct PlayerMoment {
    let playbackState: String?
    let status: StatusKeys?
}

/// A report made before its session started, sent with that session's identity once it does.
private struct Held {
    /// The handle that made it; none for Lens's own, which belong to the binding.
    let member: ObjectIdentifier?
    /// Made while a source was set: it goes if that source goes before playback is attempted.
    let underSource: Bool
    let send: (SessionState) -> Void
}

/// Reports one player may hold before its session starts; the oldest go first past this.
private let maxHeld = 100

/// The handles that share one session, and that session. Every handle joined
/// on the same player — the key, as a plain object or as an adapter's
/// `target` — is bound to one binding; that is how two SDKs on one player
/// report into one `sid` without knowing of each other. A handle without a
/// player gets a binding of its own. The binding is where a session is
/// started, continued and ended, and where Lens's own reports are built.
///
/// The first adapter joined is the one Lens observes; others join the session
/// unobserved, and the next in join order takes over when the observed one's
/// last handle leaves. Without any adapter the handles drive the session
/// themselves.
///
/// Everything here is guarded by `lock`; callers hold it unless a method says
/// otherwise. Handles on a player are retained: `dispose()` unbinds them,
/// never the collector. A handle without a player is held weakly, so dropping
/// it still deallocates it, live session or not.
internal final class Binding {
    /// Recursive: Lens's reports go out while it is held.
    let lock = NSRecursiveLock()
    /// The player this binding is for — the object itself or an adapter's
    /// `target` — kept alive while handles are on it: an `ObjectIdentifier`
    /// outlives nothing, and a freed key's could name the next object.
    let key: AnyObject?
    /// With an observed adapter, Lens watches the player and its source decides the session.
    private(set) var player: PlayerObserver?
    private var members: [WeakMember] = []
    private var retained: [SessionMember] = []
    /// What each handle joined with, in join order; only handles with an adapter.
    private var joined: [(member: WeakMember, adapter: any LensPlayerAdapter)] = []
    private var secondAdapterWarned = false
    var current: SessionState?
    /// A player's source that has not been played yet: its session starts at the first play request.
    private var waiting: SessionContext?
    private var held: [Held] = []
    private var heldOverflowWarned = false
    /// Set when the last handle leaves; nothing more happens on this binding.
    private(set) var released = false

    private final class WeakMember {
        weak var value: SessionMember?
        init(_ value: SessionMember) { self.value = value }
    }

    init(key: AnyObject?) {
        self.key = key
    }

    var handles: [SessionMember] {
        members.removeAll { $0.value == nil }
        return members.compactMap(\.value)
    }

    /// A handle joins; with an adapter, Lens observes it unless another
    /// already is — then the handle shares the session unobserved, with one
    /// warning per binding, or none under `strict`, which throws before the
    /// handle is bound. Returns the observer to attach, outside the lock, when
    /// this adapter is the one observed.
    func bind(_ handle: SessionMember, adapter: (any LensPlayerAdapter)?, strict: Bool) throws
        -> PlayerObserver?
    {
        let observed = player
        if let adapter, let observed, adapter !== observed.adapter {
            if strict {
                throw LensError.invalidOptions("Lens: another adapter already observes this player")
            }
            if !secondAdapterWarned {
                secondAdapterWarned = true
                Lens.warn(
                    "Lens: another adapter already observes this player; this one is not observed")
            }
        }
        members.append(WeakMember(handle))
        if key != nil { retained.append(handle) }
        guard let adapter else { return nil }
        joined.append((WeakMember(handle), adapter))
        guard observed == nil else { return nil }
        let observer = PlayerObserver(binding: self, adapter: adapter)
        player = observer
        return observer
    }

    /// A handle leaves; returns what to run on the main queue. The last one
    /// releases the binding. When the observed adapter has no handle left, the
    /// next adapter in join order takes over the player's playback state; with
    /// none, the session goes on driven by the handles, without player keys.
    func unbind(_ handle: SessionMember) -> (() -> Void)? {
        members.removeAll { $0.value == nil || $0.value === handle }
        retained.removeAll { $0 === handle }
        joined.removeAll { $0.member.value == nil || $0.member.value === handle }
        if handles.isEmpty { return release() }
        guard let observed = player else { return nil }
        if joined.contains(where: { $0.adapter === observed.adapter }) { return nil }
        let unsubscribe = observed.detach()
        guard let next = joined.first?.adapter else {
            player = nil
            waiting = nil
            held.removeAll()
            return unsubscribe
        }
        let replacement = PlayerObserver(
            binding: self, adapter: next, handover: observed.handover())
        player = replacement
        return {
            unsubscribe?()
            replacement.attach()
        }
    }

    // MARK: Session lifecycle

    /// A new session: the current one quits and pending events flush, a fresh
    /// `sid` starts, `sn` counts fresh per the (target, sid) rule, the ad swap
    /// closes and the heartbeats restart.
    func start(_ context: SessionContext) {
        if let replaced = current {
            quit(replaced)
            for handle in handles { handle.flushTransport() }
        }
        mint(context)
        for handle in handles { handle.sessionStarted() }
    }

    /// A player's source is set. Its session starts at the first play request
    /// on it, autoplay included — not now, nor when it preloads (data spec §5):
    /// a source only set or preloaded is not a playback. Whatever ran on the
    /// previous source ends first.
    func await(_ context: SessionContext) {
        end()
        waiting = context
        Binding.markLive(self, true)
    }

    /// Whether a source is set and its session has not started yet.
    var awaitingPlayback: Bool { waiting != nil }

    @discardableResult
    private func mint(_ context: SessionContext) -> SessionState {
        let minted = SessionState(context: context)
        current = minted
        Binding.markLive(self, true)
        return minted
    }

    /// The first play request: the session starts and what was held goes out, in order.
    private func open() -> SessionState {
        let opened = mint(waiting!)
        waiting = nil
        let sending = held
        held = []
        for entry in sending { entry.send(opened) }
        return opened
    }

    /// Holds a report made before its session started, to send once it does.
    /// Without a source set it waits for the next session; with one, it goes
    /// if that source goes first.
    func hold(_ member: SessionMember?, _ send: @escaping (SessionState) -> Void) {
        if held.count >= maxHeld {
            held.removeFirst()
            if !heldOverflowWarned {
                heldOverflowWarned = true
                Lens.warn(
                    "Lens: over \(maxHeld) reports made before playback started; dropping the oldest"
                )
            }
        }
        held.append(
            Held(member: member.map(ObjectIdentifier.init), underSource: waiting != nil, send: send)
        )
    }

    /// A member's held reports go: it left, or consent was denied.
    func dropHeld(_ member: SessionMember) {
        held.removeAll { $0.member == ObjectIdentifier(member) }
    }

    /// The stream type, as the player learns it, for the session or the one awaiting playback.
    func setStreamType(_ streamType: String?) {
        guard let streamType else { return }
        current?.streamType = streamType
        waiting?.streamType = streamType
    }

    /// The same session on a changed source: same `sid`, no flush, no
    /// heartbeat restart. The context updates and the spec's own change events
    /// fire, each only when the respective value actually changed. Before
    /// playback was attempted nothing has been reported: the source just updates.
    func `continue`(_ change: SessionContext) {
        let target =
            current.map { SessionContext(contentId: $0.contentId, hostname: $0.hostname) }
            ?? waiting
        guard let target else { return }
        let contentIdChanged =
            change.contentId != nil && target.contentId != nil
            && change.contentId != target.contentId
        let hostnameChanged =
            change.hostname != nil && target.hostname != nil && change.hostname != target.hostname
        if let current {
            if let contentId = change.contentId { current.contentId = contentId }
            if let streamingFormat = change.streamingFormat {
                current.streamingFormat = streamingFormat
            }
            if let streamType = change.streamType { current.streamType = streamType }
            if let hostname = change.hostname { current.hostname = hostname }
        } else if var updated = waiting {
            updated.contentId = change.contentId ?? updated.contentId
            updated.streamingFormat = change.streamingFormat ?? updated.streamingFormat
            updated.streamType = change.streamType ?? updated.streamType
            updated.hostname = change.hostname ?? updated.hostname
            waiting = updated
            return
        }
        let at = Lens.now()
        if contentIdChanged { report(.contentIdChange, state(), nil, at: at) }
        if hostnameChanged { report(.hostnameChange, state(), nil, at: at) }
    }

    func end() {
        // A source that goes before it was played takes what was held under it.
        waiting = nil
        held.removeAll { $0.underSource }
        Binding.markLive(self, false)
        guard let ending = current else { return }
        quit(ending)
        current = nil
        for handle in handles { handle.sessionEnded() }
    }

    /// The last handle left: stop watching the player and forget this binding.
    /// Returns the adapter's release, for the main queue.
    func release() -> (() -> Void)? {
        released = true
        guard let key else { return nil }
        Binding.registryLock.lock()
        if Binding.players[ObjectIdentifier(key)] === self {
            Binding.players.removeValue(forKey: ObjectIdentifier(key))
        }
        Binding.registryLock.unlock()
        return player?.detach()
    }

    // MARK: Lens's own reports

    /// Runs `task` under the lock — on a player binding in turn with the
    /// player's facts, right after reading it (`PlayerObserver.inTurn`).
    /// Callers do not hold the lock.
    func inTurn(_ task: @escaping () -> Void) {
        if let player {
            player.inTurn(task)
        } else {
            lock.lock()
            defer { lock.unlock() }
            task()
        }
    }

    /// The player's state now; none without a player.
    func state() -> PlayerState? {
        player?.playback.state
    }

    /// Reports derived from the player at one moment, in order.
    func reportAll(_ reports: [PlaybackReport]) {
        let at = Lens.now()
        for report in reports { self.report(report.event, report.state, report.keys, at: at) }
    }

    /// One of Lens's own reports: a state change, a player event, `c`/`h`, the
    /// quit. Stamped `lens`, with the session's own `cid` (never an open ad
    /// swap's), and routed through the first consenting handle, so the report
    /// is the same whichever handle is attached and a destination filtered on
    /// `lens` sees the whole session story. They reach every matching
    /// destination, whatever its heartbeat setting; the ones that end the
    /// session (`q`, `f`) carry its end context.
    ///
    /// Before the first play request on a source, reports are held — the
    /// preloading state `d` among them, so a played session keeps its preload
    /// context. Any other state starts the session (`s`, or a late attach's
    /// `p`, `a`, `e`…: a play request happened); a fatal error starts it and
    /// ends it.
    private func report(
        _ event: CmcdEvent, _ state: PlayerState?, _ keys: StatusKeys?, at: Int64
    ) {
        let build = lensEvent(event, state, keys, at: at)
        let route: (SessionState) -> Void = { [unowned self] current in
            // Every matching destination: only the liveness report (e=t) follows the heartbeat setting.
            handles.first { $0.hasConsent() }?.deliver(build(current), heartbeat: false)
        }
        if let current {
            route(current)
            return
        }
        guard waiting != nil else { return }
        // A source that fails before it is played is still reported (data spec §5):
        // the fatal error starts the session, what was held goes first, and the
        // session ends at once — no heartbeat ever runs on it.
        if state == .fatal {
            route(open())
            return
        }
        if event != .playStateChange || state == .preloading {
            // Held for the binding, not a handle: whichever handle consents when
            // the session starts sends it, so one leaving does not take it along.
            if handles.contains(where: { $0.hasConsent() }) { hold(nil, route) }
            return
        }
        route(open())
        for handle in handles { handle.sessionStarted() }
    }

    /// Builds now what belongs to this moment; the session's identity is filled in when it is sent.
    private func lensEvent(
        _ event: CmcdEvent, _ state: PlayerState?, _ keys: StatusKeys?, at: Int64
    ) -> (SessionState) -> LensEvent {
        let endContext =
            event == .playStateChange && (state == .quit || state == .fatal)
            ? sessionEndContext() : nil
        let moment = self.moment(state, at: at)
        var status = moment.status
        if let keys { status?.merge(keys) }
        return { [player] current in
            LensEvent(
                type: event.rawValue,
                customName: nil,
                namespace: Validation.lensNamespace,
                keys: endContext,
                timestamp: at,
                session: current.session,
                contentId: current.contentId,
                streamingFormat: current.streamingFormat,
                streamType: current.streamType,
                hostname: player != nil || event == .hostnameChange ? current.hostname : nil,
                playbackState: moment.playbackState,
                status: status
            )
        }
    }

    /// The hostname a report of the session carries: on a player session, always.
    func hostname(_ current: SessionState) -> String? {
        player != nil ? current.hostname : nil
    }

    /// What the player says at `at`, Lens's reports and the integrators' alike: the state and its keys.
    func moment(_ state: PlayerState?, at: Int64) -> PlayerMoment {
        PlayerMoment(
            playbackState: state?.rawValue,
            status: player?.playback.status(state, at: Double(at)))
    }

    /// The quit report — one `e=ps` with `sta=q` per session. Best effort by
    /// design; heartbeat silence stays the verdict when the report is lost. A
    /// player session that already ended or failed has said so: `q` is
    /// "before completion", so none follows `e` or `f`. It never waits for a
    /// read of the player: it carries the last snapshot.
    private func quit(_ ending: SessionState) {
        if ending.quitSent { return }
        ending.quitSent = true
        let state = state()
        if state == .ended || state == .fatal { return }
        report(.playStateChange, .quit, nil, at: Lens.now())
    }

    /// What a session-ending report (`sta=q`, `sta=f`) carries so the end is
    /// attributable without a join — e.g. the ad break and ad playing at the
    /// end: the consenting handles' latest heartbeat payloads, as-is, since
    /// the data spec's short-key space is global.
    private func sessionEndContext() -> LensEventKeys? {
        var keys: LensEventKeys = [:]
        for handle in handles where handle.hasConsent() {
            handle.contributeSessionEndContext(&keys)
        }
        return keys.isEmpty ? nil : keys
    }

    // MARK: The registry

    private static let registryLock = NSLock()
    /// Bindings by player key, compared by reference identity: every handle on one player shares
    /// one. A key-only binding stays registered while any handle is on it, so a later adapter finds it.
    private nonisolated(unsafe) static var players: [ObjectIdentifier: Binding] = [:]
    /// Bindings with a live session — what the termination edge must quit.
    private nonisolated(unsafe) static var live: [ObjectIdentifier: Binding] = [:]

    /// The binding for `adapter`, locked; a fresh one without. A binding
    /// released meanwhile is gone from the registry, so the next try gets a
    /// new one.
    static func lockedBinding(for key: AnyObject?) -> Binding {
        while true {
            let binding = bindingFor(key)
            binding.lock.lock()
            if !binding.released { return binding }
            binding.lock.unlock()
        }
    }

    private static func bindingFor(_ key: AnyObject?) -> Binding {
        guard let key else { return Binding(key: nil) }
        registryLock.lock()
        defer { registryLock.unlock() }
        let id = ObjectIdentifier(key)
        if let binding = players[id] { return binding }
        let binding = Binding(key: key)
        players[id] = binding
        return binding
    }

    static var attachedPlayers: [Binding] {
        registryLock.lock()
        defer { registryLock.unlock() }
        return Array(players.values)
    }

    private static func markLive(_ binding: Binding, _ isLive: Bool) {
        registryLock.lock()
        defer { registryLock.unlock() }
        live[ObjectIdentifier(binding)] = isLive ? binding : nil
    }

    // Sessions must quit before the process's final flush; the notifier rides
    // the willTerminate observer the transport installs. Backgrounding is a
    // flush only — never a session end — and, for players, a visibility change.
    static let lifecycleHooks: Void = {
        TransportRuntime.visibilityNotifier = { PlayerObserver.appVisibilityChanged(hidden: $0) }
        TransportRuntime.terminationNotifier = {
            registryLock.lock()
            let ending = Array(live.values)
            registryLock.unlock()
            for binding in ending {
                binding.lock.lock()
                binding.end()
                binding.lock.unlock()
            }
        }
    }()

    // MARK: Test seams — not part of the production path

    /// Retained handles and their binding hold each other; dropping the
    /// registry alone would leave those cycles (and their transports) alive
    /// across tests.
    static func resetForTesting() {
        registryLock.lock()
        let bindings = Array(players.values) + Array(live.values)
        players.removeAll()
        live.removeAll()
        registryLock.unlock()
        for binding in bindings {
            binding.lock.lock()
            let release = binding.release()
            binding.members.removeAll()
            binding.retained.removeAll()
            binding.joined.removeAll()
            binding.current = nil
            binding.waiting = nil
            binding.held.removeAll()
            binding.lock.unlock()
            if let release { Lens.onMain(release) }
        }
    }
}
