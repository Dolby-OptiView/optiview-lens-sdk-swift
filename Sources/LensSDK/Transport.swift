import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
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

    static func builtInIngest(backend: EffectiveBackend) -> LensDestination? {
        switch backend {
        case .production:
            return LensDestination(url: productionIngestUrl, format: .cmcd)
        case .development:
            // Unreachable without registration: `Lens.configure` gates it.
            return LensDestination(url: developmentIngestUrl!, format: .cmcd)
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

    static func post(url: String, body: String, contentType: String) {
        guard let target = URL(string: url) else { return }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        request.timeoutInterval = 5
        send(request, attemptsLeft: 2)
    }

    private static func send(_ request: URLRequest, attemptsLeft: Int) {
        guard attemptsLeft > 0 else { return }
        URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error != nil || status >= 500 {
                send(request, attemptsLeft: attemptsLeft - 1)
            }
        }.resume()
    }

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
    private let delayQueue = DispatchQueue(label: "lens-transport")

    init(destinations: [LensDestination], backend: EffectiveBackend) {
        let builtIn = TransportRuntime.builtInIngest(backend: backend)
        self.queues = ((builtIn.map { [$0] } ?? []) + destinations)
            .enumerated()
            .map { Queue($0.element, isBuiltIn: builtIn != nil && $0.offset == 0) }
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
            delayQueue.asyncAfter(deadline: .now() + .milliseconds(Int(maxDelayMs)), execute: work)
        }
    }

    /// Everything this handle has pending leaves now (session end).
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        for queue in queues { flushQueue(queue) }
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
        defer { lock.unlock() }
        guard !disposed else { return }
        for queue in queues { flushQueue(queue) }
        disposed = true
    }

    private func flushQueue(_ queue: Queue) {
        queue.timer?.cancel()
        queue.timer = nil
        guard !queue.pending.isEmpty else { return }
        let events = queue.pending
        queue.pending = []
        let url =
            queue.isBuiltIn
            ? (TransportRuntime.ingestOverride ?? queue.destination.url)
            : queue.destination.url
        let environment = EnvironmentRuntime.current()
        let reports = events.map {
            Encoding.toReport(
                $0, TransportRuntime.nextSn(url: url, sessionId: $0.session.sessionId), environment)
        }
        let (body, contentType) = Encoding.encodeBody(queue.destination.format, reports)
        if let postOverride = TransportRuntime.postOverride {
            postOverride(url, body, contentType)
        } else {
            TransportRuntime.post(url: url, body: body, contentType: contentType)
        }
    }
}
