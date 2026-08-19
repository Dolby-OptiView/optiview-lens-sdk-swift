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

    /// Fails on invalid usage (programmer error). Swappable so tests can
    /// observe violations instead of crashing the test process.
    nonisolated(unsafe) internal static var usageViolation: (String) -> Void = { message in
        preconditionFailure(message)
    }

    public static func join(_ options: LensJoinOptions) throws -> LensHandle {
        guard Validation.matches(options.namespace, Validation.setupPattern) else {
            throw LensError.invalidOptions("Lens: namespace must be 1-64 printable ASCII characters")
        }
        return Handle(options: options, backend: lockBackend())
    }

    private final class Handle: LensHandle {
        private let lock = NSLock()
        private let namespace: String
        private let strict: Bool
        private let transport: Transport
        private var consent: LensConsent
        private var current: LensSession?
        private var disposed = false

        init(options: LensJoinOptions, backend: EffectiveBackend) {
            self.namespace = options.namespace
            self.strict = options.strict
            self.transport = Transport(destinations: options.destinations, backend: backend)
            self.consent = options.consent
        }

        @discardableResult
        func startSession(_ options: LensStartSessionOptions) -> LensSession {
            if let sessionId = options.sessionId, !Validation.matches(sessionId, Validation.setupPattern) {
                Lens.usageViolation("Lens: sessionId must be 1-64 printable ASCII characters")
                return LensSession(sessionId: UUID().uuidString.lowercased())
            }
            lock.lock()
            defer { lock.unlock() }
            let session = LensSession(sessionId: options.sessionId ?? UUID().uuidString.lowercased())
            if !disposed { current = session }
            return session
        }

        func endSession() {
            lock.lock()
            current = nil
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

        func setConsent(_ consent: LensConsent) {
            lock.lock()
            guard !disposed else {
                lock.unlock()
                return
            }
            self.consent = consent
            lock.unlock()
            if consent == .denied { transport.purge() }
        }

        func dispose() {
            lock.lock()
            disposed = true
            current = nil
            lock.unlock()
            transport.dispose()
        }

        private func dispatch(type: String, customName: String?, payload: (any LensEventPayload)?) {
            let (keys, drop) = Validation.checkedCustomKeys(payload?.custom, strict: strict)
            if drop { return }
            lock.lock()
            defer { lock.unlock() }
            guard let session = current, !disposed, consent == .granted else { return }
            let event = LensEvent(
                type: type,
                customName: customName,
                namespace: namespace,
                keys: keys,
                timestamp: Lens.nowForTesting?() ?? Int64(Date().timeIntervalSince1970 * 1000),
                session: session
            )
            if let sink = Lens.sinkForTesting {
                for index in transport.declaredDestinationIndices {
                    let destination = transport.destinations[index]
                    if matches(destination, event) { sink(destination, event) }
                }
                return
            }
            for (index, destination) in transport.destinations.enumerated() where matches(destination, event) {
                transport.enqueue(index: index, event: event)
            }
        }

        private func matches(_ destination: LensDestination, _ event: LensEvent) -> Bool {
            guard let filter = destination.filter else { return true }
            if let namespaces = filter.namespaces, !namespaces.contains(event.namespace) { return false }
            if let events = filter.events, !events.contains(event.customName ?? event.type) { return false }
            return true
        }
    }
}
