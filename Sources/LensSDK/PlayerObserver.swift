import Foundation

/// Facts one turn of work may queue. Far beyond what a player fires while
/// Lens reads it once; past it, the adapter is firing a fact on every read,
/// and draining would never end.
private let maxQueuedFacts = 64

/// The playback state one observer leaves to the next adapter's on the same player.
internal struct PlaybackHandover {
    let playback: Playback
    let source: LensPlayerSource?
}

/// The wiring between one player and its binding. It talks to the adapter
/// (the subscription and snapshot reads, on the main queue only, never while
/// the binding's lock is held) and to the app's visibility, and it decides
/// the session from the player's source: a new source starts one, a
/// continuation keeps it, no source ends it. What the rest means in CMCD it
/// leaves to its `Playback`, and hands the reports that returns to the
/// binding to send.
internal final class PlayerObserver {
    let playback: Playback
    private weak var binding: Binding?
    let adapter: any LensPlayerAdapter

    // Guarded by the binding's lock.
    private var unsubscribe: (() -> Void)?
    /// Set by the first fact; the contract makes that `initial`, and any later one a repeat.
    private var initialized: Bool
    /// The player's source, kept to restart a session on it after one ended.
    private var source: LensPlayerSource?
    /// The app's visibility was known at attach, so its changes count.
    private var observesApp = false
    private var warnedOffMain = false

    // Main queue only.
    /// Facts the adapter fired while Lens was busy on this player; see `turn`.
    private var queue: [LensPlayerFact] = []
    private var running = false
    /// Facts queued in the current turn, against `maxQueuedFacts`.
    private var queuedThisTurn = 0

    /// With a `handover`, this observer replaces another on the same player and
    /// continues its playback: the next adapter's first `initial` is a repeat.
    init(binding: Binding, adapter: any LensPlayerAdapter, handover: PlaybackHandover? = nil) {
        self.binding = binding
        self.adapter = adapter
        self.playback = handover?.playback ?? Playback(now: { Double(Lens.now()) })
        self.initialized = handover != nil
        self.source = handover?.source
    }

    /// What the next adapter's observer continues from, once this one is detached. Under the lock.
    func handover() -> PlaybackHandover {
        playback.handover()
        return PlaybackHandover(playback: playback, source: source)
    }

    /// On the first handle, on the main queue: subscribe; the adapter's
    /// `initial` fact brings the player's current state. Callers do not hold
    /// the lock.
    func attach() {
        Lens.onMain { [self] in
            let hidden = Lens.appHidden()
            guard let binding, attached else { return }
            withLock { _ in
                if let hidden {
                    observesApp = true
                    _ = playback.page(hidden: hidden)
                }
            }
            let release = adapter.subscribe { [weak self] fact in self?.receive(fact) }
            binding.lock.lock()
            let late = binding.released
            if !late { unsubscribe = release }
            binding.lock.unlock()
            if late { release() }
        }
    }

    /// On the last handle's dispose, under the lock: facts that still arrive
    /// are ignored. Returns the adapter's release, for the main queue.
    func detach() -> (() -> Void)? {
        defer { unsubscribe = nil }
        return unsubscribe
    }

    /// Runs Lens's work on this player — a report that reads the player —
    /// on the main queue, in turn with the player's facts: right after a
    /// fresh read, under the lock. From another queue the work waits for the
    /// main queue rather than read where the read is not allowed. Callers do
    /// not hold the lock.
    func inTurn(_ task: @escaping () -> Void) {
        Lens.onMain { [self] in turn { afterRead(task) } }
    }

    /// The app went to the background or came back — the iOS/tvOS counterpart
    /// of a web page's visibility. Called by the transport's UIKit lifecycle
    /// observers, before the background flush, and by tests.
    static func appVisibilityChanged(hidden: Bool) {
        for binding in Binding.attachedPlayers { binding.player?.appChanged(hidden: hidden) }
    }

    // MARK: Turns

    /// One turn of Lens's work on this player — a fact, an app change, a
    /// report that reads the player. An adapter may fire a fact from inside
    /// `snapshot()` or from a callback a report sets off; such a fact waits
    /// until the work in progress is done, so facts apply in the order they
    /// happened and no report is built across one. Work Lens starts from
    /// inside runs at once. One turn queues at most `maxQueuedFacts`; the rest
    /// are dropped. Main queue only.
    private func turn(_ work: () -> Void) {
        if running {
            work()
            return
        }
        running = true
        queuedThisTurn = 0
        work()
        while !queue.isEmpty { handle(queue.removeFirst()) }
        running = false
    }

    /// Facts arrive on the main queue. One delivered elsewhere breaks the
    /// contract; it is moved there rather than read where the read is not
    /// allowed.
    private func receive(_ fact: LensPlayerFact) {
        guard Thread.isMainThread else {
            let first = withLock { _ -> Bool in
                defer { warnedOffMain = true }
                return !warnedOffMain
            }
            if first == true {
                Lens.warn(
                    "Lens: a player fact arrived off the main queue; adapters deliver facts there")
            }
            DispatchQueue.main.async { [weak self] in self?.receive(fact) }
            return
        }
        if !running {
            turn { handle(fact) }
        } else if queuedThisTurn < maxQueuedFacts {
            queuedThisTurn += 1
            queue.append(fact)
        } else if queuedThisTurn == maxQueuedFacts {
            queuedThisTurn += 1
            Lens.warn(
                "Lens: player adapter fired over \(maxQueuedFacts) facts while Lens was handling "
                    + "one (from inside snapshot()?); dropping the rest")
        }
    }

    /// Reads the player for this moment, outside the lock, then runs `task`
    /// under it. Nothing runs once the player is released.
    private func afterRead(_ task: () -> Void) {
        guard let binding, attached else { return }
        let snapshot = adapter.snapshot()
        binding.lock.lock()
        defer { binding.lock.unlock() }
        guard !binding.released else { return }
        playback.observe(snapshot)
        task()
    }

    /// Whether the binding still has handles; checked before every adapter call.
    private var attached: Bool { withLock { _ in true } ?? false }

    /// Runs `body` under the binding's lock; nil once the binding is gone or released.
    private func withLock<T>(_ body: (Binding) -> T) -> T? {
        guard let binding else { return nil }
        binding.lock.lock()
        defer { binding.lock.unlock() }
        return binding.released ? nil : body(binding)
    }

    private func appChanged(hidden: Bool) {
        Lens.onMain { [self] in
            turn {
                let reports =
                    withLock { _ in observesApp ? playback.page(hidden: hidden) : [] } ?? []
                if !reports.isEmpty { afterRead { binding?.reportAll(reports) } }
            }
        }
    }

    // MARK: Facts and sessions

    private func handle(_ fact: LensPlayerFact) {
        afterRead {
            if case .initial = fact {} else { initialized = true }
            switch fact {
            case .initial(let source, let properties): initial(source, properties)
            case .source(let source, let properties, let continuation):
                sourceChanged(source, continuation, properties)
            case .change(let properties): changed(properties)
            default: playbackFact(fact)
            }
        }
    }

    private func initial(_ next: LensPlayerSource?, _ properties: LensPlayerProperties) {
        if initialized {
            // A repeated `initial` is taken as the change it describes, never
            // as a fresh start: the same source keeps its session, another is a
            // new source.
            if sameSource(usableSource(next), source) {
                changed(properties)
            } else {
                sourceChanged(next, false, properties)
            }
            return
        }
        initialized = true
        playback.reset(properties)
        source = usableSource(next)
        guard let source, let binding else { return }
        if binding.current != nil {
            // A session the handles started on this player's key: Lens takes it
            // over on its `sid`; the player's state joins as on a late attach.
            let reports = playback.begin(source, lateAttach: true)
            binding.continue(sessionContext(for: source))
            binding.reportAll(reports)
            return
        }
        startSession(source, lateAttach: true)
    }

    private func sourceChanged(
        _ next: LensPlayerSource?, _ continuation: Bool, _ properties: LensPlayerProperties
    ) {
        guard let binding else { return }
        source = usableSource(next)
        if let source, binding.current != nil || binding.awaitingPlayback, continuation {
            let context = sourceContext(source, continuation: true)
            binding.continue(
                SessionContext(
                    contentId: context.contentId,
                    streamingFormat: context.streamingFormat?.rawValue,
                    hostname: context.hostname))
            changed(properties)
            return
        }
        // The old session ends on what it was; the new source starts from its own properties.
        binding.end()
        playback.newSource(properties)
        if let source { startSession(source, lateAttach: false) }
    }

    private func changed(_ properties: LensPlayerProperties) {
        let reports = playback.change(properties)
        binding?.setStreamType(playback.streamType()?.rawValue)
        binding?.reportAll(reports)
    }

    private func playbackFact(_ fact: LensPlayerFact) {
        guard let binding else { return }
        if binding.current == nil && !binding.awaitingPlayback {
            // Playback resuming on a player whose session ended (after a fatal
            // error) starts a fresh one on the same source.
            guard fact == .play || fact == .playing, let source else { return }
            startSession(source, lateAttach: false)
        }
        binding.reportAll(playback.apply(fact))
        // A fatal error is the end of the session, like a quit but reported as
        // `sta=f`: nothing more can happen on it, so its heartbeats stop too.
        if playback.state == .fatal { binding.end() }
    }

    /// The source awaits its first play request, which starts the session:
    /// the opening state when it is one (autoplay, a late attach to a player
    /// that was played), else a later fact. A preload is held until then.
    private func startSession(_ source: LensPlayerSource, lateAttach: Bool) {
        guard let binding else { return }
        binding.await(sessionContext(for: source))
        binding.reportAll(playback.begin(source, lateAttach: lateAttach))
    }

    private func sessionContext(for source: LensPlayerSource) -> SessionContext {
        let context = sourceContext(source)
        return SessionContext(
            contentId: context.contentId,
            streamingFormat: context.streamingFormat?.rawValue,
            streamType: playback.streamType()?.rawValue,
            hostname: context.hostname)
    }
}
