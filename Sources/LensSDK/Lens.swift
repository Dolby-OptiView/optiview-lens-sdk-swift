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
        Binding.resetForTesting()
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
        _ = Binding.lifecycleHooks
        return Handle(options: options, backend: lockBackend())
    }

    /// Epoch milliseconds, as every report stamps them.
    internal static func now() -> Int64 {
        nowForTesting?() ?? Int64(Date().timeIntervalSince1970 * 1000)
    }

    /// Whether the app is in the background, read when a player attaches:
    /// UIKit's application state, nil without one — then only the adapter's
    /// view counts. Swappable so tests can stand in for the app.
    nonisolated(unsafe) internal static var appHidden: () -> Bool? = {
        TransportRuntime.applicationInBackground
    }

    /// Runs `work` on the main queue — the only queue Lens calls an adapter
    /// on: right away when already there, else as soon as it is free.
    internal static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - Handles

    /// One integrator's side of a session: the API, its own reports (events and
    /// heartbeats, in its namespace) and its delivery. Sessions themselves live
    /// on the binding (Session.swift).
    private final class Handle: LensHandle, SessionMember {
        private let binding: Binding
        /// The binding's lock — handles on a player share it with the session.
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
        /// Bumped whenever the cadence stops, so a tick already on its way to
        /// the main queue cannot outlive the cadence it belongs to.
        private var cadence = 0
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
            let binding = Binding.lockedBinding(for: options.player)
            self.binding = binding
            self.lock = binding.lock
            self.heartbeatMs = options.heartbeatMs
            teardown.add(transport.dispose)
            binding.bind(self)
            let attach = binding.player != nil && binding.handles.count == 1
            let opening = !attach && restartCadence()
            let cadence = self.cadence
            lock.unlock()
            if attach {
                binding.player?.attach()
            } else if opening {
                beat(cadence)
            }
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
            if binding.player != nil && !disposed {
                Lens.warn("Lens: startSession() ignored — sessions on a player are Lens-owned")
            }
            if disposed || binding.player != nil {
                return binding.current?.session
                    ?? LensSession(sessionId: options.sessionId ?? Lens.sessionIdFactory())
            }
            // Starting while a session runs rolls it.
            binding.start(
                SessionContext(
                    sessionId: options.sessionId, contentId: options.contentId,
                    streamingFormat: options.streamingFormat, streamType: options.streamType))
            return binding.current!.session
        }

        func endSession() {
            lock.lock()
            if disposed {
                lock.unlock()
                return
            }
            if binding.player != nil {
                lock.unlock()
                Lens.warn("Lens: endSession() ignored — sessions on a player are Lens-owned")
                return
            }
            if binding.current != nil {
                binding.end()
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
            if binding.player != nil {
                Lens.warn("Lens: reportSourceChange() ignored — Lens observes the player source")
                return
            }
            guard let current = binding.current else { return }
            if !change.newSession {
                binding.continue(
                    SessionContext(
                        contentId: change.contentId, streamingFormat: change.streamingFormat,
                        hostname: change.hostname))
                return
            }
            binding.start(
                SessionContext(
                    contentId: change.contentId ?? current.contentId,
                    streamingFormat: change.streamingFormat ?? current.streamingFormat,
                    streamType: current.streamType,
                    hostname: change.hostname ?? current.hostname))
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
            dispatch(type: CmcdEvent.customEvent.rawValue, customName: name, payload: payload)
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
            guard !disposed, ms != heartbeatMs else {
                lock.unlock()
                return
            }
            heartbeatMs = ms
            let opening = restartCadence()
            let cadence = self.cadence
            lock.unlock()
            if opening { beat(cadence) }
        }

        func setConsent(_ consent: LensConsent) {
            lock.lock()
            guard !disposed, self.consent != consent else {
                lock.unlock()
                return
            }
            self.consent = consent
            // Denial silences the cadence rather than ticking into a drop.
            let opening = restartCadence()
            let cadence = self.cadence
            lock.unlock()
            if consent == .denied {
                transport.purge()
                lock.lock()
                binding.dropHeld(self)
                lock.unlock()
                UserIdRuntime.clear()
            }
            if opening { beat(cadence) }
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
            if binding.current != nil && binding.handles.count == 1 { binding.end() }
            binding.dropHeld(self)
            binding.unbind(self)
            let release = binding.handles.isEmpty ? binding.release() : nil
            disposed = true
            adContentId = nil
            stopHeartbeat = nil
            lock.unlock()
            teardown.release()
            if let release { Lens.onMain(release) }
        }

        // MARK: SessionMember — called by the binding, under its lock

        /// A session started or rolled on this handle's binding — by a fact,
        /// whose snapshot is this moment's, or by the door, without a player.
        func sessionStarted() {
            adContentId = nil
            if restartCadence() { emitHeartbeat() }
        }

        func sessionEnded() {
            adContentId = nil
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
        func contributeSessionEndContext(_ keys: inout LensEventKeys) {
            guard let snapshot = heartbeatKeys else { return }
            keys.merge(snapshot) { _, new in new }
        }

        func deliver(_ event: LensEvent, heartbeat: Bool) {
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

        // MARK: This handle's own reports

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
            // Without a session, a player's handle holds the report until
            // playback starts one (data spec §5); a handle without a player drops it.
            guard !disposed, consent == .granted, binding.current != nil || binding.player != nil
            else {
                lock.unlock()
                return
            }
            let contentId = effectiveContentId(type: type, adCid: adCid)
            lock.unlock()
            binding.inTurn { [self] in
                guard !disposed, consent == .granted else { return }
                let build = buildEvent(
                    type: type, keys: keys, customName: customName, contentId: contentId)
                if let current = binding.current {
                    deliver(build(current), heartbeat: false)
                } else if binding.player != nil {
                    binding.hold(self) { [self] opened in deliver(build(opened), heartbeat: false) }
                }
            }
        }

        /// The §8.2.8 `cid` sequence: an ad start opens a swap with its own
        /// content ID — and always closes the previous one, so back-to-back
        /// starts in a pod never label the new ad with the old ad's id. The
        /// swap is also bounded by the ad's end/skip, the break's end, and
        /// session end/roll — an unmatched start can never mislabel reports
        /// past its break. `adEnd`/`adSkip` may carry their own ID
        /// (out-of-order labeling) without re-opening a swap; `adBreakEnd` is
        /// always the main content's. Nil is the session's own `cid`, filled in
        /// when the report is built. Callers hold `lock`.
        private func effectiveContentId(type: String, adCid: String?) -> String? {
            switch type {
            case "as":
                adContentId = adCid
                return adCid
            case "ae", "sk":
                let cid = adCid ?? adContentId
                adContentId = nil
                return cid
            case "abe":
                adContentId = nil
                return nil
            default:
                return adContentId
            }
        }

        /// One liveness report of `cadence`, on a fresh read of the player.
        private func beat(_ cadence: Int) {
            binding.inTurn { [weak self] in
                guard let self, cadence == self.cadence else { return }
                self.emitHeartbeat()
            }
        }

        /// The session's liveness report (`e=t`), always in this handle's
        /// namespace — a receiver's liveness stream must not come and go with
        /// the integrator's state. Reaches only destinations that take
        /// heartbeats. Callers hold `lock`.
        private func emitHeartbeat() {
            guard let current = binding.current, !disposed, consent == .granted else { return }
            // Always the session's cid — §8.2.8 shifts only the ad events, and a
            // liveness stream that flips identity mid-break is worse to consume.
            deliver(
                buildEvent(type: CmcdEvent.timeInterval.rawValue, keys: heartbeatKeys)(current),
                heartbeat: true)
        }

        /// One of this handle's reports, in its namespace, carrying what every
        /// report of the session carries at this moment; the session's identity
        /// is filled in when it is sent, which for a held report is later.
        /// Callers hold `lock`, and on a player have just read it.
        private func buildEvent(
            type: String, keys: LensEventKeys?, customName: String? = nil,
            contentId: String? = nil
        ) -> (SessionState) -> LensEvent {
            let at = Lens.now()
            let moment = binding.moment(binding.state(), at: at)
            return { [namespace, binding] current in
                LensEvent(
                    type: type,
                    customName: customName,
                    namespace: namespace,
                    keys: keys,
                    timestamp: at,
                    session: current.session,
                    // The session's cid unless an ad swap is open.
                    contentId: contentId ?? current.contentId,
                    streamingFormat: current.streamingFormat,
                    streamType: current.streamType,
                    hostname: binding.hostname(current),
                    playbackState: moment.playbackState,
                    status: moment.status
                )
            }
        }

        /// One timer at a time, and only while a consenting session is live. A
        /// cadence opens with a report, the way CTA-5004-B §8.2.2's interval
        /// stream starts at the session's first moment: a receiver hears the
        /// session immediately, and a cadence change never leaves a gap longer
        /// than the interval it replaced. Returns whether the cadence opened,
        /// owing that report — sent by the caller once the player is read.
        /// Callers hold `lock`.
        private func restartCadence() -> Bool {
            cancelHeartbeat()
            guard !disposed, binding.current != nil, consent == .granted, heartbeatMs != 0 else {
                return false
            }
            let cadence = self.cadence
            stopHeartbeat = teardown.add(
                Lens.ticker(heartbeatMs) { [weak self] in self?.beat(cadence) })
            return true
        }

        // Callers hold `lock`.
        private func cancelHeartbeat() {
            stopHeartbeat?()
            stopHeartbeat = nil
            cadence += 1
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
