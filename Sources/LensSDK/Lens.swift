import Foundation

public enum Lens {
    nonisolated(unsafe) private static var configuredBackend: EffectiveBackend?
    private static let backendLock = NSLock()

    public static func configure(_ options: LensConfigureOptions) throws {
        backendLock.lock()
        defer { backendLock.unlock() }
        try setBackend(options.backend == .disabled ? .disabled : .production)
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
    }

    /// Internal delivery seam for the API-semantics tests.
    nonisolated(unsafe) internal static var sinkForTesting: ((LensDestination, LensEvent) -> Void)?

    /// Test seam: deterministic timestamps for the behavioral fixtures.
    nonisolated(unsafe) internal static var nowForTesting: (() -> Int64)?

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

    public static func join(_ options: LensJoinOptions) throws -> LensHandle {
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
        return Handle(options: options, backend: lockBackend())
    }

    private final class Handle: LensHandle {
        private let lock = NSLock()
        private let namespace: String
        private let strict: Bool
        private let transport: Transport
        private let heartbeatMs: Int64
        private var consent: LensConsent
        private var current: LensSession?
        private var disposed = false
        private var stopHeartbeat: (() -> Void)?
        private var heartbeatKeys: LensEventKeys?
        private var sessionContentId: String?
        private var streamingFormat: String?
        private var streamType: String?

        // The ad's `cid` while a §8.2.8 swap is open; cleared when the ad or break ends.
        private var adContentId: String?

        /// The ad events whose typed payload may carry the ad's content ID (§8.2.8).
        private static let adCidEvents: Set<String> = ["as", "ae", "sk"]

        init(options: LensJoinOptions, backend: EffectiveBackend) {
            self.namespace = options.namespace
            self.strict = options.strict
            self.transport = Transport(destinations: options.destinations, backend: backend)
            self.consent = options.consent
            self.heartbeatMs = options.heartbeatMs
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
            let session = LensSession(
                sessionId: options.sessionId ?? UUID().uuidString.lowercased())
            if !disposed {
                current = session
                sessionContentId = options.contentId
                streamingFormat = options.streamingFormat
                streamType = options.streamType
                adContentId = nil
            }
            armHeartbeat()
            return session
        }

        func endSession() {
            lock.lock()
            current = nil
            sessionContentId = nil
            streamingFormat = nil
            streamType = nil
            adContentId = nil
            cancelHeartbeat()
            lock.unlock()
            transport.flush()
        }

        var session: LensSession? {
            lock.lock()
            defer { lock.unlock() }
            return current
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
            if consent == .denied { transport.purge() }
        }

        func dispose() {
            lock.lock()
            disposed = true
            current = nil
            sessionContentId = nil
            streamingFormat = nil
            streamType = nil
            adContentId = nil
            cancelHeartbeat()
            lock.unlock()
            transport.dispose()
        }

        private func dispatch(type: String, customName: String?, payload: (any LensEventPayload)?) {
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
            guard let session = current, !disposed, consent == .granted else { return }
            let event = LensEvent(
                type: type,
                customName: customName,
                namespace: namespace,
                keys: keys,
                timestamp: Lens.nowForTesting?() ?? Int64(Date().timeIntervalSince1970 * 1000),
                session: session,
                contentId: effectiveContentId(type: type, adCid: adCid),
                streamingFormat: streamingFormat,
                streamType: streamType
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
        private func effectiveContentId(type: String, adCid: String?) -> String? {
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
            guard let session = current, !disposed, consent == .granted else { return }
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
                    session: session,
                    contentId: sessionContentId,
                    streamingFormat: streamingFormat,
                    streamType: streamType
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

        /// One timer at a time, and only while a consenting session is live.
        /// Callers hold `lock`.
        private func armHeartbeat() {
            cancelHeartbeat()
            guard !disposed, current != nil, consent == .granted, heartbeatMs != 0 else { return }
            stopHeartbeat = Lens.ticker(heartbeatMs) { [weak self] in self?.heartbeat() }
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
