import Foundation

public enum Lens {
    nonisolated(unsafe) private static var configuredBackend: EffectiveBackend?
    private static let backendLock = NSLock()

    /// "One Lens copy per app" (docs/distribution.md): with the packaging
    /// rule holding, this type is process-global and nothing more is needed.
    /// A statically linked or vendored second copy escapes that guarantee
    /// silently — this rendezvous through a string-keyed process-global
    /// environment entry exists to make it loud.
    private static let duplicateCopyCheck: Void = detectDuplicateCopy()

    internal static func detectDuplicateCopy() {
        let key = "com.dolby.optiview.lens"
        let identity = String(describing: ObjectIdentifier(Lens.self))
        if let existing = getenv(key).map({ String(cString: $0) }) {
            if existing != identity {
                duplicateCopyWarning(
                    "Lens: another copy of the Lens SDK is loaded in this process "
                        + "(\(existing) and \(identity)). "
                        + "Ship one Lens copy per app — see docs/distribution.md.")
            }
            return
        }
        setenv(key, identity, 0)
    }

    /// A duplicate copy is a packaging mistake, not a reason to abort the host
    /// app — warn, like Android and web. Swappable so tests can observe it.
    nonisolated(unsafe) internal static var duplicateCopyWarning: (String) -> Void = { message in
        print("[Lens] \(message)")
    }

    public static func configure(_ options: LensConfigureOptions) throws {
        _ = duplicateCopyCheck
        backendLock.lock()
        defer { backendLock.unlock() }
        try setBackend(options.backend == .disabled ? .disabled : .production)
        TransportRuntime.lifecycleFlush = options.lifecycleFlush
    }

    /// Wiring for the LensSDKDev product — registers the development ingest
    /// URL and locks the backend to it. Registration is one-shot: once a URL
    /// is registered it cannot be replaced, so no other library in the host
    /// app can redirect telemetry.
    public static func useDevelopmentBackend(url: String) throws {
        backendLock.lock()
        defer { backendLock.unlock() }
        guard TransportRuntime.registerDevelopmentIngestUrl(url) else {
            throw LensError.invalidOptions("Lens: a development ingest URL is already registered")
        }
        try setBackend(.development)
    }

    // Callers hold backendLock.
    private static func setBackend(_ backend: EffectiveBackend) throws {
        if let current = configuredBackend, current != backend {
            throw LensError.invalidOptions("Lens: backend is already locked to '\(current)'")
        }
        configuredBackend = backend
    }

    private static func lockBackend() -> EffectiveBackend {
        backendLock.lock()
        defer { backendLock.unlock() }
        let backend = configuredBackend ?? .production
        configuredBackend = backend
        return backend
    }

    internal static func resetConfigurationForTesting() {
        backendLock.lock()
        defer { backendLock.unlock() }
        configuredBackend = nil
        TransportRuntime.resetDevelopmentIngestForTesting()
        bindingLock.lock()
        let bindings = Array(anchorBindings.values) + Array(liveBindings.values)
        anchorBindings.removeAll()
        liveBindings.removeAll()
        bindingLock.unlock()
        // Retained handles and their binding hold each other; dropping the
        // maps alone would leave those cycles (and their transports) alive
        // across tests.
        for binding in bindings {
            binding.lock.lock()
            binding.unbindAllForTesting()
            binding.lock.unlock()
        }
    }

    /// Internal delivery seam for the API-semantics tests.
    nonisolated(unsafe) internal static var sinkForTesting: ((LensDestination, LensEvent) -> Void)?

    /// Test seam: deterministic timestamps for the behavioral fixtures.
    nonisolated(unsafe) internal static var nowForTesting: (() -> Int64)?

    /// Test seam: deterministic session IDs for the behavioral fixtures.
    nonisolated(unsafe) internal static var sessionIdFactory: () -> String = {
        UUID().uuidString.lowercased()
    }

    /// Starts a repeating tick; the returned closure stops it. A dispatch timer
    /// coalesces periods missed while the app was suspended instead of firing a
    /// catch-up burst. Swappable so tests drive the cadence by hand.
    nonisolated(unsafe) internal static var ticker: (Int64, @escaping () -> Void) -> () -> Void = {
        intervalMs, tick in
        let queue = DispatchQueue(label: "com.dolby.optiview.lens.heartbeat")
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(Int(intervalMs))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler(handler: tick)
        timer.activate()
        return { timer.cancel() }
    }

    /// Fails on invalid usage (programmer error). Swappable so tests can
    /// observe violations instead of crashing the test process.
    nonisolated(unsafe) internal static var usageViolation: (String) -> Void = { message in
        preconditionFailure(message)
    }

    /// The SDK's diagnostic channel, for what has no caller to answer to.
    nonisolated(unsafe) internal static var warn: (String) -> Void = { message in
        print(message)
    }

    public static func join(_ options: LensJoinOptions) throws -> LensHandle {
        _ = duplicateCopyCheck
        guard Validation.matches(options.namespace, Validation.setupPattern) else {
            throw LensError.invalidOptions(
                "Lens: namespace must be 1-64 printable ASCII characters")
        }
        guard options.namespace.lowercased() != Validation.lensNamespace else {
            throw LensError.invalidOptions(
                "Lens: namespace '\(Validation.lensNamespace)' is reserved for the SDK's own reports"
            )
        }
        guard options.heartbeatMs == 0 || options.heartbeatMs >= Validation.minHeartbeatMs else {
            throw LensError.invalidOptions(
                "Lens: heartbeatMs must be 0 (off) or at least \(Validation.minHeartbeatMs) milliseconds"
            )
        }
        if let batch = options.batch {
            if let maxEvents = batch.maxEvents {
                guard maxEvents >= 1 else {
                    throw LensError.invalidOptions(
                        "Lens: batch.maxEvents must be a whole number >= 1")
                }
            }
            if let maxDelayMs = batch.maxDelayMs {
                guard (0...2_147_483_647).contains(maxDelayMs) else {
                    throw LensError.invalidOptions(
                        "Lens: batch.maxDelayMs must be a whole number of milliseconds from 0 to 2147483647"
                    )
                }
            }
        }
        _ = terminationHook
        return Handle(options: options, backend: lockBackend())
    }

    // MARK: - The session manager

    // The only place a sid is ever minted, rotated, or ended. Sessions are
    // internal objects, never public API: integrators see only the read-only
    // `LensSession` through `handle.session`.
    private final class SessionState {
        let session: LensSession
        var contentId: String?
        var streamingFormat: String?
        var streamType: String?
        var hostname: String?
        /// The handle whose boundary signal minted this session — the only one
        /// whose endSession() ends it. Weak so a dropped unanchored handle keeps
        /// deallocating as before bindings existed; an anchored minter stays
        /// alive through the binding's retained handles.
        private(set) weak var minter: Handle?
        var quitSent = false

        init(
            session: LensSession, contentId: String?, streamingFormat: String?,
            streamType: String?, hostname: String?, minter: Handle
        ) {
            self.session = session
            self.contentId = contentId
            self.streamingFormat = streamingFormat
            self.streamType = streamType
            self.hostname = hostname
            self.minter = minter
        }
    }

    private final class WeakHandle {
        weak var value: Handle?
        init(_ value: Handle) { self.value = value }
    }

    /// One player's session slot and the handles bound to it — or one unanchored handle's own.
    /// Anchored handles are retained, as on Web and Android: `dispose()` is
    /// what unbinds them, on every platform — never the collector. The
    /// membership list and the live session's hold on its minter both stay
    /// weak, so nothing here roots an unanchored handle — dropping one still
    /// deallocates it, live session or not.
    private final class Binding {
        /// Recursive: the source-change policy emits change events while holding it.
        let lock = NSRecursiveLock()
        let anchor: AnyObject?
        private var handles: [WeakHandle] = []
        private var retained: [Handle] = []
        var current: SessionState?

        init(anchor: AnyObject?) {
            self.anchor = anchor
        }

        var boundHandles: [Handle] {
            handles.removeAll { $0.value == nil }
            return handles.compactMap(\.value)
        }

        var isEmpty: Bool { boundHandles.isEmpty }

        func bind(_ handle: Handle) {
            handles.append(WeakHandle(handle))
            if anchor != nil { retained.append(handle) }
        }

        func unbind(_ handle: Handle) {
            handles.removeAll { $0.value == nil || $0.value === handle }
            retained.removeAll { $0 === handle }
        }

        func unbindAllForTesting() {
            handles.removeAll()
            retained.removeAll()
            current = nil
        }
    }

    /// Anchors compare by reference identity — a player is the same player, never an equal one.
    private static let bindingLock = NSLock()
    private nonisolated(unsafe) static var anchorBindings: [ObjectIdentifier: Binding] = [:]
    /// Bindings with a live session — what the termination edge must quit.
    private nonisolated(unsafe) static var liveBindings: [ObjectIdentifier: Binding] = [:]

    private static func bindingFor(_ anchor: AnyObject?) -> Binding {
        guard let anchor else { return Binding(anchor: nil) }
        bindingLock.lock()
        defer { bindingLock.unlock() }
        let key = ObjectIdentifier(anchor)
        if let binding = anchorBindings[key] { return binding }
        let binding = Binding(anchor: anchor)
        anchorBindings[key] = binding
        return binding
    }

    // Sessions must quit before the process's final flush; the notifier rides
    // the willTerminate observer the transport installs. Backgrounding is a
    // flush only — never a session end.
    private static let terminationHook: Void = {
        TransportRuntime.terminationNotifier = {
            bindingLock.lock()
            let live = Array(liveBindings.values)
            bindingLock.unlock()
            for binding in live {
                binding.lock.lock()
                endBindingSession(binding)
                binding.lock.unlock()
            }
        }
    }()

    // Callers hold the binding's lock.
    private static func mintSession(
        _ binding: Binding, minter: Handle, context: LensStartSessionOptions
    ) {
        // A repeat boundary signal rolls: the replaced session ends, so it quits.
        if let replaced = binding.current {
            emitQuit(binding, replaced)
            let handles = binding.boundHandles
            for handle in handles { handle.flushTransport() }
        }
        binding.current = SessionState(
            session: LensSession(sessionId: context.sessionId ?? sessionIdFactory()),
            contentId: context.contentId,
            streamingFormat: context.streamingFormat,
            streamType: context.streamType,
            hostname: nil,
            minter: minter
        )
        markLive(binding, live: true)
        for handle in binding.boundHandles { handle.sessionStarted() }
    }

    private static func markLive(_ binding: Binding, live: Bool) {
        bindingLock.lock()
        defer { bindingLock.unlock() }
        let key = ObjectIdentifier(binding)
        if live {
            liveBindings[key] = binding
        } else {
            liveBindings.removeValue(forKey: key)
        }
    }

    /// A new session is exactly today's roll: the old session quits, pending
    /// events flush, heartbeats restart, `sn` counts fresh per the
    /// (target, sid) rule, the ad swap closes. A continued session keeps the
    /// sid: the context updates and the spec's own change events fire, each
    /// only when the respective value actually changed — no flush, no
    /// heartbeat restart. Callers hold the binding's lock.
    private static func applySourceChange(
        _ binding: Binding, reporter: Handle, change: LensSourceChange
    ) {
        guard let current = binding.current else { return }
        if change.newSession {
            emitQuit(binding, current)
            let handles = binding.boundHandles
            for handle in handles { handle.flushTransport() }
            binding.current = SessionState(
                session: LensSession(sessionId: sessionIdFactory()),
                contentId: change.contentId ?? current.contentId,
                streamingFormat: change.streamingFormat ?? current.streamingFormat,
                streamType: current.streamType,
                hostname: change.hostname ?? current.hostname,
                minter: current.minter ?? reporter
            )
            for handle in handles { handle.sessionStarted() }
            return
        }
        let contentIdChanged =
            change.contentId != nil && current.contentId != nil
            && change.contentId != current.contentId
        let hostnameChanged =
            change.hostname != nil && current.hostname != nil
            && change.hostname != current.hostname
        if let contentId = change.contentId { current.contentId = contentId }
        if let streamingFormat = change.streamingFormat {
            current.streamingFormat = streamingFormat
        }
        if let hostname = change.hostname { current.hostname = hostname }
        guard let router = sessionRouter(binding, current) else { return }
        if contentIdChanged { router.deliverSessionEvent("c", current, hostname: nil) }
        if hostnameChanged { router.deliverSessionEvent("h", current, hostname: change.hostname) }
    }

    /// The handle a session-level report rides: the minter while it consents,
    /// else the first consenting handle — so the report does not depend on
    /// which bound handle happened to speak.
    private static func sessionRouter(_ binding: Binding, _ current: SessionState) -> Handle? {
        let contributors = binding.boundHandles.filter { $0.hasConsent() }
        return contributors.first(where: { $0 === current.minter }) ?? contributors.first
    }

    // Callers hold the binding's lock.
    private static func endBindingSession(_ binding: Binding) {
        guard let current = binding.current else { return }
        emitQuit(binding, current)
        binding.current = nil
        markLive(binding, live: false)
        for handle in binding.boundHandles { handle.sessionEnded() }
    }

    /// The quit report — one `e=ps` with `sta=q` per session, in the reserved
    /// `lens` namespace, through one bound handle's transport. Bound handles'
    /// latest heartbeat-payload snapshots ride it as-is — the data spec's
    /// short-key space is global, so no qualification is needed. Best effort
    /// by design; heartbeat silence stays the verdict when the report is lost.
    private static func emitQuit(_ binding: Binding, _ current: SessionState) {
        if current.quitSent { return }
        current.quitSent = true
        guard let router = sessionRouter(binding, current) else { return }
        var keys: LensEventKeys = [:]
        for handle in binding.boundHandles where handle.hasConsent() {
            handle.contributeQuitContext(&keys)
        }
        router.deliverQuit(current, keys: keys.isEmpty ? nil : keys)
    }

    private final class Handle: LensHandle {
        private let binding: Binding
        /// The binding's lock — anchored handles share it with the session manager.
        private let lock: NSRecursiveLock
        private let namespace: String
        private let strict: Bool
        private let transport: Transport
        /// Every registration this handle makes; `dispose()` releases exactly this set.
        private let teardown = Teardown()
        private var heartbeatMs: Int64
        private var consent: LensConsent
        private var disposed = false
        private var stopHeartbeat: (() -> Void)?
        /// Set by this handle's own boundary signal; only then does it heartbeat.
        private var signaled = false
        private var heartbeatKeys: LensEventKeys?

        // The ad's `cid` while a §8.2.8 swap is open; cleared when the ad or break ends.
        private var adContentId: String?

        /// The ad events whose typed payload may carry the ad's content ID (§8.2.8).
        private static let adCidEvents: Set<String> = ["as", "ae", "sk"]

        init(options: LensJoinOptions, backend: EffectiveBackend) {
            self.namespace = options.namespace
            self.strict = options.strict
            self.transport = Transport(
                destinations: options.destinations,
                backend: backend,
                ingestBatch: options.batch
            )
            self.consent = options.consent
            let binding = Lens.bindingFor(options.player)
            self.binding = binding
            self.lock = binding.lock
            teardown.add(transport.dispose)
            self.heartbeatMs = options.heartbeatMs
            lock.lock()
            binding.bind(self)
            lock.unlock()
        }

        @discardableResult
        func startSession(_ options: LensStartSessionOptions) -> LensSession {
            if let sessionId = options.sessionId,
                !Validation.matches(sessionId, Validation.setupPattern)
            {
                Lens.usageViolation("Lens: sessionId must be 1-64 printable ASCII characters")
                return LensSession(sessionId: UUID().uuidString.lowercased())
            }
            if let contentId = options.contentId,
                !Validation.matches(contentId, Validation.contentIdPattern)
            {
                Lens.usageViolation("Lens: contentId must be 1-128 printable ASCII characters")
                return LensSession(sessionId: UUID().uuidString.lowercased())
            }
            if let streamingFormat = options.streamingFormat,
                !Validation.sfTokens.contains(streamingFormat)
            {
                Lens.usageViolation("Lens: streamingFormat must be one of 'd', 'h', 's', 'e', 'o'")
                return LensSession(sessionId: UUID().uuidString.lowercased())
            }
            if let streamType = options.streamType, !Validation.stTokens.contains(streamType) {
                Lens.usageViolation("Lens: streamType must be one of 'v', 'l', 'll'")
                return LensSession(sessionId: UUID().uuidString.lowercased())
            }
            lock.lock()
            defer { lock.unlock() }
            if disposed {
                return LensSession(sessionId: options.sessionId ?? Lens.sessionIdFactory())
            }
            // A boundary signal on a live shared session joins it — only the
            // minting handle's signal rolls. Without an anchor the handle is
            // always the minter, so the door rolls exactly as before.
            signaled = true
            if let current = binding.current, current.minter !== self {
                armHeartbeat()
                return current.session
            }
            Lens.mintSession(binding, minter: self, context: options)
            return binding.current!.session
        }

        func endSession() {
            lock.lock()
            if disposed {
                lock.unlock()
                return
            }
            if let current = binding.current, current.minter !== self {
                lock.unlock()
                Lens.warn(
                    "Lens: endSession() ignored — the session is shared and was not started by this handle"
                )
                return
            }
            if binding.current != nil {
                Lens.endBindingSession(binding)
                lock.unlock()
                return
            }
            cancelHeartbeat()
            lock.unlock()
            transport.flush()
        }

        func reportSourceChange(_ change: LensSourceChange) {
            if let contentId = change.contentId,
                !Validation.matches(contentId, Validation.contentIdPattern)
            {
                Lens.usageViolation("Lens: contentId must be 1-128 printable ASCII characters")
                return
            }
            if let hostname = change.hostname,
                !Validation.matches(hostname, Validation.hostnamePattern)
            {
                Lens.usageViolation("Lens: hostname must be 1-128 printable ASCII characters")
                return
            }
            if let streamingFormat = change.streamingFormat,
                !Validation.sfTokens.contains(streamingFormat)
            {
                Lens.usageViolation("Lens: streamingFormat must be one of 'd', 'h', 's', 'e', 'o'")
                return
            }
            lock.lock()
            defer { lock.unlock() }
            guard !disposed else { return }
            Lens.applySourceChange(binding, reporter: self, change: change)
        }

        var session: LensSession? {
            lock.lock()
            defer { lock.unlock() }
            return disposed ? nil : binding.current?.session
        }

        func emit<P: LensEventPayload>(_ type: LensEventType<P>, payload: P?) {
            dispatch(type: type.wireCode, customName: nil, payload: payload)
        }

        func emitCustom(_ name: String, payload: LensPayload?) {
            guard Validation.checkedCustomEventName(name, strict: strict) else { return }
            dispatch(type: "ce", customName: name, payload: payload)
        }

        func setHeartbeatPayload(_ payload: LensPayload?) {
            // Validated here, on the caller's thread and stack, so strict mode
            // can report at the line that got it wrong — a tick has nobody to
            // blame, and integrator code never runs on the timer queue.
            let (checked, drop) = Validation.checkedCustomKeys(payload?.custom, strict: strict)
            if drop { return }
            lock.lock()
            defer { lock.unlock() }
            guard !disposed else { return }
            heartbeatKeys = checked
        }

        func setHeartbeatInterval(_ ms: Int64) {
            guard ms == 0 || ms >= Validation.minHeartbeatMs else {
                Lens.usageViolation(
                    "Lens: heartbeatMs must be 0 (off) or at least \(Validation.minHeartbeatMs) milliseconds"
                )
                return
            }
            lock.lock()
            defer { lock.unlock() }
            guard !disposed, ms != heartbeatMs else { return }
            heartbeatMs = ms
            armHeartbeat()
        }

        func setConsent(_ consent: LensConsent) {
            lock.lock()
            guard !disposed else {
                lock.unlock()
                return
            }
            guard self.consent != consent else {
                lock.unlock()
                return
            }
            self.consent = consent
            // Denial silences the cadence rather than ticking into a drop.
            armHeartbeat()
            lock.unlock()
            if consent == .denied {
                transport.purge()
                UserIdRuntime.clear()
            }
        }

        func flush() {
            lock.lock()
            let disposed = self.disposed
            lock.unlock()
            guard !disposed else { return }
            transport.flush()
        }

        func dispose() {
            lock.lock()
            if disposed {
                lock.unlock()
                return
            }
            // The last bound handle leaving is a session end — the quit report
            // goes out through this handle before its transport is released.
            if binding.current != nil && binding.boundHandles.count == 1 {
                Lens.endBindingSession(binding)
            }
            binding.unbind(self)
            if let anchor = binding.anchor, binding.isEmpty {
                Lens.bindingLock.lock()
                Lens.anchorBindings.removeValue(forKey: ObjectIdentifier(anchor))
                Lens.bindingLock.unlock()
            }
            disposed = true
            adContentId = nil
            stopHeartbeat = nil
            lock.unlock()
            teardown.release()
        }

        // MARK: Session-manager edges; module-internal, not part of LensHandle.
        // All run under the binding's lock.

        /// A session minted or rotated on this handle's binding.
        func sessionStarted() {
            adContentId = nil
            if signaled { armHeartbeat() }
        }

        /// The binding's session ended; quiet the cadence and let pending posts go.
        func sessionEnded() {
            adContentId = nil
            signaled = false
            cancelHeartbeat()
            transport.flush()
        }

        func flushTransport() {
            transport.flush()
        }

        func hasConsent() -> Bool {
            !disposed && consent == .granted
        }

        /// This handle's latest heartbeat-payload snapshot, as registered —
        /// the data spec's short-key space is global.
        func contributeQuitContext(_ keys: inout LensEventKeys) {
            guard let snapshot = heartbeatKeys else { return }
            keys.merge(snapshot) { _, new in new }
        }

        /// The session's quit report (`e=ps`, `sta=q`) — Lens's own, in the
        /// reserved namespace. Session lifecycle rides the liveness stream: it
        /// reaches only destinations that take heartbeats.
        func deliverQuit(_ current: SessionState, keys: LensEventKeys?) {
            deliver(
                LensEvent(
                    type: "ps",
                    customName: nil,
                    namespace: Validation.lensNamespace,
                    keys: keys,
                    timestamp: Lens.nowForTesting?() ?? Int64(Date().timeIntervalSince1970 * 1000),
                    session: current.session,
                    contentId: current.contentId,
                    streamingFormat: current.streamingFormat,
                    streamType: current.streamType,
                    playbackState: "q"
                ),
                heartbeat: true
            )
        }

        /// A same-session change report (`e=c` / `e=h`) — Lens's own, in the
        /// reserved namespace, with the session's own `cid`: the session
        /// changed, not any producer's ad.
        func deliverSessionEvent(_ type: String, _ current: SessionState, hostname: String?) {
            deliver(
                LensEvent(
                    type: type,
                    customName: nil,
                    namespace: Validation.lensNamespace,
                    keys: nil,
                    timestamp: Lens.nowForTesting?() ?? Int64(Date().timeIntervalSince1970 * 1000),
                    session: current.session,
                    contentId: current.contentId,
                    streamingFormat: current.streamingFormat,
                    streamType: current.streamType,
                    hostname: hostname
                ),
                heartbeat: false
            )
        }

        private func dispatch(
            type: String, customName: String?, payload: (any LensEventPayload)?
        ) {
            let (keys, drop) = Validation.checkedCustomKeys(payload?.custom, strict: strict)
            if drop { return }
            var adCid: String?
            if Handle.adCidEvents.contains(type) {
                let (checked, dropEvent) = Validation.checkedContentId(
                    (payload as? LensAdPayload)?.contentId, strict: strict)
                if dropEvent { return }
                adCid = checked
            }
            lock.lock()
            defer { lock.unlock() }
            guard let current = binding.current, !disposed, consent == .granted else { return }
            let event = LensEvent(
                type: type,
                customName: customName,
                namespace: namespace,
                keys: keys,
                timestamp: Lens.nowForTesting?() ?? Int64(Date().timeIntervalSince1970 * 1000),
                session: current.session,
                contentId: effectiveContentId(
                    type: type, adCid: adCid, sessionContentId: current.contentId),
                streamingFormat: current.streamingFormat,
                streamType: current.streamType
            )
            deliver(event, heartbeat: false)
        }

        /// The §8.2.8 `cid` sequence: an ad start opens a swap with its own
        /// content ID — and always closes the previous one, so back-to-back
        /// starts in a pod never label the new ad with the old ad's id. The
        /// swap is also bounded by the ad's end/skip, the break's end, and
        /// session end/roll — an unmatched start can never mislabel reports
        /// past its break. `adEnd`/`adSkip` may carry their own ID
        /// (out-of-order labeling) without re-opening a swap; `adBreakEnd` is
        /// always the main content's. Callers hold `lock`.
        private func effectiveContentId(type: String, adCid: String?, sessionContentId: String?)
            -> String?
        {
            switch type {
            case "as":
                adContentId = adCid
                return adCid ?? sessionContentId
            case "ae", "sk":
                let cid = adCid ?? adContentId ?? sessionContentId
                adContentId = nil
                return cid
            case "abe":
                adContentId = nil
                return sessionContentId
            default:
                return adContentId ?? sessionContentId
            }
        }

        /// The session's liveness report (`e=t`), one per tick, always in this
        /// handle's namespace — a receiver's liveness stream must not come and
        /// go with the integrator's state. Reaches only destinations that take
        /// heartbeats.
        private func heartbeat() {
            lock.lock()
            defer { lock.unlock() }
            emitHeartbeat()
        }

        // Callers hold `lock`.
        private func emitHeartbeat() {
            guard let current = binding.current, !disposed, consent == .granted else { return }
            let keys = heartbeatKeys
            // Always the session's cid — §8.2.8 shifts only the ad events, and a
            // liveness stream that flips identity mid-break is worse to consume.
            deliver(
                LensEvent(
                    type: "t",
                    customName: nil,
                    namespace: namespace,
                    keys: keys,
                    timestamp: Lens.nowForTesting?() ?? Int64(Date().timeIntervalSince1970 * 1000),
                    session: current.session,
                    contentId: current.contentId,
                    streamingFormat: current.streamingFormat,
                    streamType: current.streamType
                ),
                heartbeat: true
            )
        }

        // Callers hold `lock`.
        private func deliver(_ event: LensEvent, heartbeat: Bool) {
            func eligible(_ destination: LensDestination) -> Bool {
                matches(destination, event) && (!heartbeat || takesHeartbeat(destination))
            }
            if let sink = Lens.sinkForTesting {
                for index in transport.declaredDestinationIndices {
                    let destination = transport.destinations[index]
                    if eligible(destination) { sink(destination, event) }
                }
                return
            }
            for (index, destination) in transport.destinations.enumerated()
            where eligible(destination) {
                transport.enqueue(index: index, event: event)
            }
        }

        /// One timer at a time, and only while a consenting session is live. A
        /// cadence opens with a report, the way CTA-5004-B §8.2.2's interval
        /// stream starts at the session's first moment: a receiver hears the
        /// session immediately, and a cadence change never leaves a gap longer
        /// than the interval it replaced.
        /// Callers hold `lock`.
        private func armHeartbeat() {
            cancelHeartbeat()
            guard !disposed, binding.current != nil, consent == .granted, heartbeatMs != 0 else {
                return
            }
            stopHeartbeat = teardown.add(
                Lens.ticker(heartbeatMs) { [weak self] in self?.heartbeat() })
            emitHeartbeat()
        }

        // Callers hold `lock`.
        private func cancelHeartbeat() {
            stopHeartbeat?()
            stopHeartbeat = nil
        }

        /// CMCD event targets get liveness by default; any other format opts in.
        private func takesHeartbeat(_ destination: LensDestination) -> Bool {
            destination.heartbeat ?? (destination.format == .cmcd)
        }

        private func matches(_ destination: LensDestination, _ event: LensEvent) -> Bool {
            guard let filter = destination.filter else { return true }
            if let namespaces = filter.namespaces, !namespaces.contains(event.namespace) {
                return false
            }
            if let events = filter.events, !events.contains(event.customName ?? event.type) {
                return false
            }
            return true
        }
    }
}
