import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if canImport(UIKit)
    import UIKit
#endif

/// Event delivery: per-handle batching, process-wide (mode, target, sid)
/// sequencing, posting. Mechanics: docs/internals.md.
internal enum TransportRuntime {
    static let productionIngestUrl = "https://data-ingest-api.dolby.io/api/v1/cmcd/events"
    static let maxTrackedSids = 64

    /// The development ingest URL never lives in the core module: the dev
    /// product (LensSDKDev) registers it, so a build that doesn't link it
    /// cannot contain it.
    private nonisolated(unsafe) static var _developmentIngestUrl: String?
    private static let developmentIngestLock = NSLock()

    static var developmentIngestUrl: String? {
        developmentIngestLock.lock()
        defer { developmentIngestLock.unlock() }
        return _developmentIngestUrl
    }

    /// One-shot: registration fails once a different URL is registered.
    static func registerDevelopmentIngestUrl(_ url: String) -> Bool {
        developmentIngestLock.lock()
        defer { developmentIngestLock.unlock() }
        if let current = _developmentIngestUrl, current != url { return false }
        _developmentIngestUrl = url
        return true
    }

    static func resetDevelopmentIngestForTesting() {
        developmentIngestLock.lock()
        defer { developmentIngestLock.unlock() }
        _developmentIngestUrl = nil
    }

    static func builtInIngest(
        backend: EffectiveBackend,
        ingestBatch: LensBatch?
    ) -> LensDestination? {
        switch backend {
        case .production:
            return LensDestination(url: productionIngestUrl, format: .cmcd, batch: ingestBatch)
        case .development:
            // Unreachable without registration: `Lens.configure` gates it.
            return LensDestination(url: developmentIngestUrl!, format: .cmcd, batch: ingestBatch)
        case .disabled:
            return nil
        }
    }

    /// Sequence numbers per (mode, target, sid) — shared across handles by design.
    private nonisolated(unsafe) static var snRegistry: [String: [(sid: String, sn: Int)]] = [:]
    private static let snLock = NSLock()

    static func nextSn(url: String, sessionId: String) -> Int {
        snLock.lock()
        defer { snLock.unlock() }
        var perSid = snRegistry["event|\(url)"] ?? []
        let previous = perSid.first(where: { $0.sid == sessionId })?.sn ?? 0
        perSid.removeAll { $0.sid == sessionId }
        perSid.append((sid: sessionId, sn: previous + 1))
        if perSid.count > maxTrackedSids { perSid.removeFirst() }
        snRegistry["event|\(url)"] = perSid
        return previous + 1
    }

    // Response policy (CTA-5004-B §5): 2xx delivered, 410 cease, 429/5xx/
    // network error backoff, any other 4xx dropped. Backoff and cease are per
    // target URL, process-wide — two handles sharing a target must not each
    // hammer it.
    static let maxRetries = 3
    static let maxHeldEvents = 128
    private static let retryAfterCapMs = 30000
    private static let defaultBackoffBaseMs = 1000

    nonisolated(unsafe) static var backoffBaseMs = defaultBackoffBaseMs
    nonisolated(unsafe) static var lifecycleFlush = true

    // The transport-level edge is where the process's end is observed;
    // sessions are handle-level state, so the session layer registers here to
    // emit its quit reports before the final flush. Termination only — a
    // background is a flush, never a session end.
    nonisolated(unsafe) static var terminationNotifier: (() -> Void)?

    /// Retries and delayed re-flushes ride here — one queue for the process,
    /// so handles sharing a target coordinate their backoff.
    static let delayQueue = DispatchQueue(label: "lens-transport")

    private static let policyLock = NSLock()
    private nonisolated(unsafe) static var backoffUntil: [String: Date] = [:]
    /// Bumped by the test reset so already-scheduled retries die quietly
    /// instead of leaking into the next test; constant in production.
    private nonisolated(unsafe) static var policyEpoch = 0
    private nonisolated(unsafe) static var scheduledRetries = 0
    private nonisolated(unsafe) static var ceasedTargets: Set<String> = []
    private nonisolated(unsafe) static var warnedTargets: Set<String> = []

    /// Posts (including their scheduled retries) not yet resolved — what the
    /// background-task assertion waits out.
    private nonisolated(unsafe) static var inFlight = 0

    static func isCeased(_ url: String) -> Bool {
        policyLock.lock()
        defer { policyLock.unlock() }
        return ceasedTargets.contains(url)
    }

    static func backoffRemaining(_ url: String) -> TimeInterval {
        policyLock.lock()
        defer { policyLock.unlock() }
        return backoffUntil[url].map { $0.timeIntervalSinceNow } ?? 0
    }

    static var inFlightCount: Int {
        policyLock.lock()
        defer { policyLock.unlock() }
        return inFlight
    }

    private static func warnOnce(_ kind: String, _ url: String, _ message: String) {
        policyLock.lock()
        let first = warnedTargets.insert("\(kind)|\(url)").inserted
        policyLock.unlock()
        if first { print("[Lens] \(message)") }
    }

    /// Handles kept weakly — registration must never outlive the integrator's
    /// own reference.
    private final class WeakTransport {
        weak var value: Transport?
        init(_ value: Transport) { self.value = value }
    }

    private nonisolated(unsafe) static var liveTransports: [WeakTransport] = []
    private static let liveLock = NSLock()

    static func register(_ transport: Transport) {
        liveLock.lock()
        liveTransports.removeAll { $0.value == nil }
        liveTransports.append(WeakTransport(transport))
        #if canImport(UIKit)
            let install = !lifecycleObserved
            lifecycleObserved = true
            liveLock.unlock()
            if install { installLifecycleObservers() }
        #else
            liveLock.unlock()
        #endif
    }

    static func unregister(_ transport: Transport) {
        liveLock.lock()
        liveTransports.removeAll { $0.value == nil || $0.value === transport }
        #if canImport(UIKit)
            var stale: [NSObjectProtocol] = []
            if liveTransports.isEmpty && lifecycleObserved {
                lifecycleObserved = false
                stale = lifecycleTokens
                lifecycleTokens = []
            }
            liveLock.unlock()
            for token in stale { NotificationCenter.default.removeObserver(token) }
        #else
            liveLock.unlock()
        #endif
    }

    /// Everything pending on every live handle leaves now (app backgrounded).
    static func flushAll() {
        liveLock.lock()
        let snapshot = liveTransports.compactMap(\.value)
        liveLock.unlock()
        for transport in snapshot { transport.flush() }
    }

    #if canImport(UIKit)
        /// `UIApplication.shared` through the runtime, so the module stays
        /// linkable in extension-API-only targets (where it is nil).
        static var sharedApplication: UIApplication? {
            UIApplication.perform(NSSelectorFromString("sharedApplication"))?
                .takeUnretainedValue() as? UIApplication
        }
    #endif

    static func post(url: String, body: String, contentType: String) {
        guard let target = URL(string: url) else { return }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 5
        policyLock.lock()
        inFlight += 1
        policyLock.unlock()
        attempt(request, url: url, attempt: 0)
    }

    private static func settle() {
        policyLock.lock()
        inFlight -= 1
        policyLock.unlock()
    }

    private static func attempt(_ request: URLRequest, url: String, attempt attemptNumber: Int) {
        URLSession.shared.dataTask(with: request) { _, response, error in
            let http = response as? HTTPURLResponse
            let status = error == nil ? (http?.statusCode ?? 0) : 0
            switch status {
            case 200...299:
                clearBackoff(url)
                settle()
            case 410:
                policyLock.lock()
                ceasedTargets.insert(url)
                policyLock.unlock()
                warnOnce(
                    "cease", url,
                    "Lens: \(url) answered 410 Gone — ceasing delivery to it for this run")
                settle()
            case 429, 0,
                _ where status >= 500:
                guard attemptNumber < maxRetries else {
                    // The cooldown stays: another batch to this target may
                    // have just extended it, and giving up says nothing
                    // about the target's health.
                    warnOnce(
                        "drop", url,
                        "Lens: dropping a batch for \(url) after \(maxRetries) failed retries")
                    settle()
                    return
                }
                let delayMs =
                    retryAfterMs(http, status: status)
                    ?? Int(
                        Double(backoffBaseMs << attemptNumber) * (0.8 + Double.random(in: 0..<0.4))
                    )
                policyLock.lock()
                backoffUntil[url] = Date().addingTimeInterval(Double(delayMs) / 1000)
                policyLock.unlock()
                policyLock.lock()
                let epoch = policyEpoch
                scheduledRetries += 1
                policyLock.unlock()
                delayQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs)) {
                    policyLock.lock()
                    let stale = policyEpoch != epoch
                    if !stale { scheduledRetries -= 1 }
                    policyLock.unlock()
                    // A stale retry was already settled by the reset.
                    if stale { return }
                    self.attempt(request, url: url, attempt: attemptNumber + 1)
                }
            default:
                // A malformed or refused request won't get better — and a
                // final 3xx means the platform already followed what it was
                // willing to follow.
                settle()
            }
        }.resume()
    }

    private static func clearBackoff(_ url: String) {
        policyLock.lock()
        backoffUntil[url] = nil
        policyLock.unlock()
    }

    /// Delta-seconds only, capped — the HTTP-date form isn't worth the parser.
    static func retryAfterMs(_ response: HTTPURLResponse?, status: Int) -> Int? {
        guard status == 429 || status == 503, let response else { return nil }
        let header = response.allHeaderFields.first {
            ("\($0.key)").caseInsensitiveCompare("Retry-After") == .orderedSame
        }
        guard let value = header?.value as? String,
            let seconds = Int(value.trimmingCharacters(in: .whitespaces)), seconds >= 0
        else { return nil }
        return min(seconds * 1000, retryAfterCapMs)
    }

    // --- Lifecycle flushing (iOS/tvOS; the dev host has no UIKit and no cliffs) ---

    // The observers follow transport membership: installed on the live set's
    // 0 -> 1 transition, removed with their tokens on the return to 0,
    // reinstalled with the next transport. After the last dispose, an app
    // background runs no SDK code. Both variables are guarded by `liveLock`
    // — the transition and the set it watches must agree — and
    // NotificationCenter is only ever called outside it.
    #if canImport(UIKit)
        private nonisolated(unsafe) static var lifecycleObserved = false
        private nonisolated(unsafe) static var lifecycleTokens: [NSObjectProtocol] = []

        private static func installLifecycleObservers() {
            let center = NotificationCenter.default
            let tokens = [
                center.addObserver(
                    forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil
                ) { _ in backgroundFlush() },
                center.addObserver(
                    forName: UIApplication.willTerminateNotification, object: nil, queue: nil
                ) { _ in
                    // Ending the session is not lifecycle flushing: a host
                    // that opted out still gets its sessions ended here.
                    terminationNotifier?()
                    if lifecycleFlush {
                        flushAll()
                    }
                },
            ]
            liveLock.lock()
            // Keep only into an empty slot: a concurrent unregister may have
            // emptied the live set (observed false), or a concurrent
            // register/unregister/register cycle may have installed another
            // pair first (slot taken) — either way ours are stale.
            let keep = lifecycleObserved && lifecycleTokens.isEmpty
            if keep { lifecycleTokens = tokens }
            liveLock.unlock()
            if !keep { for token in tokens { center.removeObserver(token) } }
        }
    #endif

    #if canImport(UIKit)
        /// Backgrounding suspends the process before URLSession callbacks run,
        /// so the flush rides a background-task assertion: ended as soon as
        /// nothing is in flight, and bounded to a few seconds either way.
        private static func backgroundFlush() {
            guard lifecycleFlush else { return }
            let assertion = BackgroundAssertion()
            flushAll()
            endWhenIdle(assertion, deadline: Date().addingTimeInterval(5))
        }

        private static func endWhenIdle(_ assertion: BackgroundAssertion, deadline: Date) {
            if inFlightCount == 0 || Date() >= deadline {
                assertion.end()
                return
            }
            delayQueue.asyncAfter(deadline: .now() + .milliseconds(200)) {
                endWhenIdle(assertion, deadline: deadline)
            }
        }

        private final class BackgroundAssertion {
            private let lock = NSLock()
            private var taskId = UIBackgroundTaskIdentifier.invalid

            init() {
                taskId =
                    sharedApplication?.beginBackgroundTask { [weak self] in self?.end() }
                    ?? .invalid
            }

            func end() {
                lock.lock()
                let id = taskId
                taskId = .invalid
                lock.unlock()
                if id != .invalid { sharedApplication?.endBackgroundTask(id) }
            }
        }
    #endif

    // --- Test seams — not part of the production path ---

    /// Test/e2e seam: point the built-in ingest somewhere else (mock receiver, dev toggle).
    nonisolated(unsafe) static var ingestOverride: String?

    /// Test seam: capture posts synchronously instead of hitting the network.
    nonisolated(unsafe) static var postOverride: ((String, String, String) -> Void)?

    static func resetSnRegistryForTesting() {
        snLock.lock()
        defer { snLock.unlock() }
        snRegistry = [:]
    }

    static var liveTransportCountForTesting: Int {
        liveLock.lock()
        defer { liveLock.unlock() }
        return liveTransports.compactMap(\.value).count
    }

    #if canImport(UIKit)
        static var lifecycleObserverCountForTesting: Int {
            liveLock.lock()
            defer { liveLock.unlock() }
            return lifecycleTokens.count
        }
    #endif

    static func resetDeliveryPolicyForTesting() {
        policyLock.lock()
        backoffUntil = [:]
        ceasedTargets = []
        warnedTargets = []
        policyEpoch += 1
        inFlight -= scheduledRetries
        scheduledRetries = 0
        policyLock.unlock()
        backoffBaseMs = defaultBackoffBaseMs
        lifecycleFlush = true
    }
}

/// Per-handle delivery: owns this handle's queues, nothing else's.
internal final class Transport {
    private final class Queue {
        let destination: LensDestination
        let isBuiltIn: Bool
        var pending: [LensEvent] = []
        var timer: DispatchWorkItem?

        init(_ destination: LensDestination, isBuiltIn: Bool) {
            self.destination = destination
            self.isBuiltIn = isBuiltIn
        }
    }

    private let lock = NSLock()
    private let queues: [Queue]
    private var disposed = false

    init(destinations: [LensDestination], backend: EffectiveBackend, ingestBatch: LensBatch?) {
        let builtIn = TransportRuntime.builtInIngest(backend: backend, ingestBatch: ingestBatch)
        self.queues = ((builtIn.map { [$0] } ?? []) + destinations)
            .enumerated()
            .map { Queue($0.element, isBuiltIn: builtIn != nil && $0.offset == 0) }
        TransportRuntime.register(self)
    }

    /// The handle's delivery targets, with enabled built-in ingest first.
    var destinations: [LensDestination] { queues.map(\.destination) }
    var declaredDestinationIndices: [Int] {
        queues.indices.filter { !queues[$0].isBuiltIn }
    }

    func enqueue(index: Int, event: LensEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !disposed, queues.indices.contains(index) else { return }
        let queue = queues[index]
        queue.pending.append(event)

        let maxEvents = queue.destination.batch?.maxEvents ?? 1
        if queue.pending.count >= maxEvents {
            flushQueue(queue)
            return
        }
        if let maxDelayMs = queue.destination.batch?.maxDelayMs, queue.timer == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.flushQueue(queue)
            }
            queue.timer = work
            TransportRuntime.delayQueue.asyncAfter(
                deadline: .now() + .milliseconds(Int(maxDelayMs)), execute: work)
        }
    }

    /// Everything this handle has pending leaves now (session end).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        for queue in queues { flushQueue(queue, bypassCooldown: true) }
    }

    /// Consent revoked: this handle's pending events are dropped, not sent.
    func purge() {
        lock.lock()
        defer { lock.unlock() }
        for queue in queues {
            queue.timer?.cancel()
            queue.timer = nil
            queue.pending = []
        }
    }

    func dispose() {
        lock.lock()
        let alreadyDisposed = disposed
        if !alreadyDisposed {
            for queue in queues { flushQueue(queue, bypassCooldown: true) }
            disposed = true
        }
        lock.unlock()
        if !alreadyDisposed { TransportRuntime.unregister(self) }
    }

    private func flushQueue(_ queue: Queue, bypassCooldown: Bool = false) {
        queue.timer?.cancel()
        queue.timer = nil
        guard !queue.pending.isEmpty else { return }
        let url =
            queue.isBuiltIn
            ? (TransportRuntime.ingestOverride ?? queue.destination.url)
            : queue.destination.url
        // The drop sits here, not at enqueue: heartbeats keep arriving at a
        // ceased queue, and they must go nowhere.
        if TransportRuntime.isCeased(url) {
            queue.pending = []
            return
        }
        let coolOff = TransportRuntime.backoffRemaining(url)
        // An explicit flush posts even into a cooldown: it fires at lifecycle
        // cliffs, where a held queue would otherwise die with the process.
        if coolOff > 0 && !bypassCooldown {
            // Hold events while the target waits out its backoff — fewer,
            // larger posts (§5 item 12). Bounded: connectivity buffering is
            // #124's job.
            if queue.pending.count > TransportRuntime.maxHeldEvents {
                queue.pending.removeFirst(queue.pending.count - TransportRuntime.maxHeldEvents)
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.flushQueue(queue)
            }
            queue.timer = work
            TransportRuntime.delayQueue.asyncAfter(
                deadline: .now() + .milliseconds(Int(coolOff * 1000) + 1), execute: work)
            return
        }
        let events = queue.pending
        queue.pending = []
        let environment = EnvironmentRuntime.current()
        let userId = UserIdRuntime.currentUserId()
        let reports = events.map {
            Encoding.toReport(
                $0, TransportRuntime.nextSn(url: url, sessionId: $0.session.sessionId),
                environment, userId)
        }
        let (body, contentType) = Encoding.encodeBody(queue.destination.format, reports)
        if let postOverride = TransportRuntime.postOverride {
            postOverride(url, body, contentType)
        } else {
            TransportRuntime.post(url: url, body: body, contentType: contentType)
        }
    }
}
