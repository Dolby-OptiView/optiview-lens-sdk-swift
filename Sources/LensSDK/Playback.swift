import Foundation

/// What the player's model means in CMCD: the playback state machine and
/// every report key, per player. Facts, properties, snapshots and the app's
/// visibility in; states, events and keys out. It never talks to the
/// adapter, never starts or ends a session and never sends anything — that
/// is PlayerObserver's and the binding's job. Mechanics: docs/internals.md.

/// A report Lens owes the session because of a fact: the event, the state it describes, its one-off keys.
internal struct PlaybackReport: Equatable {
    let event: CmcdEvent
    /// The state the report describes — before a fatal error's own state change.
    let state: PlayerState?
    var keys: StatusKeys?
}

/// The facts that move the state machine; an error is handled on its own.
internal enum TransitionFact: CaseIterable {
    case play
    case playing
    case pause
    case waiting
    case seeking
    case seeked
    case ended
    case waitingForInput

    init?(_ fact: LensPlayerFact) {
        switch fact {
        case .play: self = .play
        case .playing: self = .playing
        case .pause: self = .pause
        case .waiting: self = .waiting
        case .seeking: self = .seeking
        case .seeked: self = .seeked
        case .ended: self = .ended
        case .waitingForInput: self = .waitingForInput
        case .initial, .source, .change, .error: return nil
        }
    }
}

/// `nil` is a session before its first state; `fatal` is final, so nothing leaves it.
private let anyState: [PlayerState?] = [
    nil, .starting, .playing, .seeking, .rebuffering, .paused, .waiting, .ended, .preloading,
]

private struct Transition {
    let from: [PlayerState?]
    let to: PlayerState
    var ifPaused: PlayerState?
}

/// Which states each fact moves out of, and where to; in any other state the
/// fact changes nothing. `seeked` lands where the player is, paused or not.
private let transitions: [TransitionFact: Transition] = [
    .play: Transition(from: [nil, .preloading, .waiting, .ended], to: .starting),
    .playing: Transition(from: anyState, to: .playing),
    .pause: Transition(from: [.starting, .playing, .rebuffering, .seeking], to: .paused),
    // Rebuffering "is not reported during startup or seeking".
    .waiting: Transition(from: [.playing], to: .rebuffering),
    .seeking: Transition(from: [.playing, .paused, .rebuffering, .ended], to: .seeking),
    .seeked: Transition(from: [.seeking], to: .playing, ifPaused: .paused),
    .ended: Transition(from: anyState, to: .ended),
    .waitingForInput: Transition(from: anyState.filter { $0 != .ended }, to: .waiting),
]

/// The state `fact` moves `state` to, or nil when it does not move it.
internal func nextState(_ state: PlayerState?, _ fact: TransitionFact, paused: Bool)
    -> PlayerState?
{
    let transition = transitions[fact]!
    guard transition.from.contains(state) else { return nil }
    return paused ? transition.ifPaused ?? transition.to : transition.to
}

/// Gaps up to this size between buffered ranges count as buffered: players skip them.
private let bufferGap: TimeInterval = 0.5

/// Live latency outside this window is a broken clock or reference, not a latency.
private let maxLatencyMs: Double = 3_600_000

/// Object types per track kind, in the order inner lists carry them.
private let mediaKinds: [(LensTrackKind, String)] = [
    (.video, "v"), (.audio, "a"), (.muxed, "av"), (.text, "c"),
]

private func presentationSize(_ mode: LensPresentationMode) -> Int {
    switch mode {
    case .pictureInPicture: return 0
    case .inline: return 1
    case .fullscreen: return 2
    }
}

/// A value the spec can carry: finite and not negative.
private func measured(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
}

/// JavaScript's `Math.round`, so every platform rounds a half the same way.
private func jsRound(_ value: Double) -> Double {
    let floor = value.rounded(.down)
    return value - floor >= 0.5 ? floor + 1 : floor
}

private func rounded(_ value: Double, _ step: Double) -> Double {
    jsRound(value / step) * step
}

/// The states `su` is about: startup, seeking, recovery after a buffer-empty event.
private func opensUrgency(_ state: PlayerState?) -> Bool {
    state == .starting || state == .seeking || state == .rebuffering
}

/// Error codes ride a structured-field string: printable ASCII only, judged
/// per UTF-16 unit as on web.
private func errorCode(_ code: String) -> String {
    let units = code.utf16.map { unit -> UInt16 in
        if unit < 0x20 || unit == 0x7F { return 0x20 }
        return unit > 0x7E ? 0x3F : unit
    }
    let clean = String(String(decoding: units, as: UTF16.self).prefix(64))
    return clean.isEmpty ? "unknown" : clean
}

/// Buffered media ahead of the playhead, in ms: the run of ranges from the playhead, small gaps bridged.
private func bufferAhead(_ ranges: [LensTimeRange]?, _ playhead: Double) -> Double? {
    guard let ranges else { return nil }
    let valid =
        ranges
        .filter { measured($0.start) != nil && measured($0.end) != nil && $0.end >= $0.start }
        .sorted { $0.start < $1.start }
    var reach = playhead
    for range in valid where range.start <= reach + bufferGap && range.end > reach {
        reach = range.end
    }
    return (reach - playhead) * 1000
}

private func kbps(_ bps: Double) -> Double {
    jsRound(bps / 1000)
}

private func selectedTrack(_ tracks: [LensTrack]?, _ kind: LensTrackKind) -> LensTrack? {
    tracks?.first { $0.kind == kind && $0.selected }
}

private func renditions(_ track: LensTrack) -> [LensRendition] {
    (track.renditions ?? []).filter { measured($0.bitrate) != nil }
}

/// The bitrate keys a track model yields: per object type, or aggregate when a rendition counts every media type.
private func bitrateKeys(_ tracks: [LensTrack]?) -> StatusKeys {
    var keys = StatusKeys()
    func push(_ key: CmcdKey, _ value: Double, _ ot: String?) {
        var list: [InnerListItem] = []
        if case .list(let existing) = keys[key] { list = existing }
        list.append(InnerListItem(value, ot: ot))
        keys[key] = .list(list)
    }
    for (kind, ot) in mediaKinds where kind != .text {
        guard let track = selectedTrack(tracks, kind) else { continue }
        let ladder = renditions(track)
        let loading = ladder.first { $0.id == track.loadingRenditionId }
        let rendered = ladder.first { $0.id == track.renderedRenditionId }
        let combined = (loading ?? ladder.first)?.combinedBitrate == true
        let perObject = combined ? nil : ot
        if let loading {
            push(combined ? .aggregateBitrate : .encodedBitrate, kbps(loading.bitrate), perObject)
        }
        if let rendered, !combined { push(.playheadBitrate, kbps(rendered.bitrate), ot) }
        if !ladder.isEmpty && track.partialLadder != true {
            let bitrates = ladder.map(\.bitrate)
            push(combined ? .topAggregateBitrate : .topBitrate, kbps(bitrates.max()!), perObject)
            push(
                combined ? .lowestAggregateBitrate : .lowestBitrate, kbps(bitrates.min()!),
                perObject)
        }
    }
    // Aggregates "MUST NOT be sent" when the per-object value is known.
    if keys[.encodedBitrate] != nil { keys[.aggregateBitrate] = nil }
    if keys[.topBitrate] != nil { keys[.topAggregateBitrate] = nil }
    if keys[.lowestBitrate] != nil { keys[.lowestAggregateBitrate] = nil }
    return keys
}

/// What `bc` tracks: the requested bitrate per object type, or the aggregate when that is all there is.
private func requestedBitrate(_ tracks: [LensTrack]?) -> StatusValue? {
    let keys = bitrateKeys(tracks)
    return keys[.encodedBitrate] ?? keys[.aggregateBitrate]
}

private func effectivelyMuted(_ properties: LensPlayerProperties) -> Bool? {
    if properties.muted == true || properties.volume == 0 { return true }
    if properties.muted == false || measured(properties.volume) != nil { return false }
    return nil
}

/// `bc` when the requested bitrate changes; the first rendition a player picks is a selection, not a change.
private func bitrateEvent(_ before: LensPlayerProperties, _ after: LensPlayerProperties)
    -> CmcdEvent?
{
    guard let from = requestedBitrate(before.tracks), let to = requestedBitrate(after.tracks),
        from != to
    else { return nil }
    return .bitrateChange
}

private func muteEvent(_ before: LensPlayerProperties, _ after: LensPlayerProperties)
    -> CmcdEvent?
{
    guard let from = effectivelyMuted(before), let to = effectivelyMuted(after), from != to else {
        return nil
    }
    return to ? .mute : .unmute
}

private func rateEvent(_ before: LensPlayerProperties, _ after: LensPlayerProperties)
    -> CmcdEvent?
{
    guard let from = measured(before.playbackRate), let to = measured(after.playbackRate),
        from != to
    else { return nil }
    return .playbackRateChange
}

/// `pe` / `pc` by size: picture-in-picture < inline < fullscreen.
private func presentationEvent(_ before: LensPlayerProperties, _ after: LensPlayerProperties)
    -> CmcdEvent?
{
    guard let from = before.presentationMode, let to = after.presentationMode, from != to else {
        return nil
    }
    return presentationSize(to) > presentationSize(from) ? .playerExpand : .playerCollapse
}

/// `bg`: out of the user's sight — the app in the background, or the
/// player's own view hidden; a picture-in-picture window is still visible.
/// A visible app with the view unknown counts as visible.
private func hidden(_ properties: LensPlayerProperties, _ appHidden: Bool?) -> Bool? {
    if properties.presentationMode == .pictureInPicture { return false }
    let view = properties.visibility
    if appHidden == true || view == .hidden { return true }
    return appHidden == false || view == .visible ? false : nil
}

internal final class Playback {
    private(set) var state: PlayerState?
    private var properties = LensPlayerProperties()
    /// Whether the app is in the background, as Lens observes it.
    private var appHidden: Bool?
    /// What the user could see when last known, so `b` alternates even across spells of not knowing.
    private var wasHidden: Bool?
    private var snapshot: LensPlayerSnapshot?
    private var snapshotAt: Double = 0
    private var startupFrom: Double?
    private var startupReported = false
    private var rebufferFrom: Double?
    private var starvations = 0
    private var starvedMs: Double = 0
    /// The spec's `su` window: opened by a startup, seek or rebuffer unless the
    /// buffer is already stable, closed the first time it is — on the input
    /// that says so, never on a report.
    private var urgent = false
    /// The window closed since the last startup, seek or rebuffer began: `su` lasts until the buffer *first* reaches its target.
    private var urgentSpent = false
    /// The decoder's dropped-frame counter, carried across counter resets, and
    /// its value at session start. Doubles, so no counter value can overflow.
    private var droppedLast: Double?
    private var droppedOffset: Double = 0
    private var droppedBase: Double = 0
    private let now: () -> Double

    init(now: @escaping () -> Double) {
        self.now = now
    }

    // MARK: Inputs

    /// A snapshot Lens read, at a fact or for a report of its own.
    func observe(_ next: LensPlayerSnapshot) {
        snapshot = next
        snapshotAt = now()
        if let dropped = next.droppedFrames, dropped >= 0 {
            let value = Double(dropped)
            if let last = droppedLast, value < last { droppedOffset += last }
            droppedLast = value
        }
        settleUrgency()
    }

    /// A new source's properties, taken as they are, no events.
    func newSource(_ properties: LensPlayerProperties) {
        reset(properties)
    }

    /// The initial properties: taken as they are, no events.
    func reset(_ initial: LensPlayerProperties) {
        properties = initial
        _ = visibilityEvent()
    }

    /// A new session on `source`. A late attach finds the player mid-flight and
    /// takes its state from the snapshot, without a startup it did not see.
    /// A new source's snapshot was read as the source changed, so it may still
    /// hold the old one's media: only the pushed `hasMediaData` counts here.
    func begin(_ source: LensPlayerSource, lateAttach: Bool) -> [PlaybackReport] {
        state = nil
        startupFrom = nil
        startupReported = false
        rebufferFrom = nil
        starvations = 0
        starvedMs = 0
        urgent = false
        urgentSpent = false
        if lateAttach, let snapshot {
            if snapshot.ended { return enter(.ended) }
            if !snapshot.paused { return enter(.playing) }
            if let time = measured(snapshot.currentTime), time > 0 { return enter(.paused) }
        }
        if source.autoplay == true { return enter(.starting) }
        return preloading(snapshotCounts: lateAttach)
    }

    /// The reports one playback fact produces, in order.
    func apply(_ fact: LensPlayerFact) -> [PlaybackReport] {
        if state == .fatal { return [] }
        // Media found at a fact before playback is requested was preloaded; at a
        // play request it is the startup's own.
        let preloaded = fact == .play || fact == .playing ? [] : preloading()
        return preloaded + transition(fact)
    }

    private func transition(_ fact: LensPlayerFact) -> [PlaybackReport] {
        if case .error(let fatal, let code, _) = fact {
            var keys = StatusKeys()
            keys[.errorCodes] = .strings([errorCode(code)])
            let report = PlaybackReport(event: .error, state: state, keys: keys)
            return fatal ? [report] + enter(.fatal) : [report]
        }
        guard let transitionFact = TransitionFact(fact),
            let next = nextState(state, transitionFact, paused: snapshot?.paused == true)
        else { return [] }
        return enter(next)
    }

    /// The new properties, whole, and the events their change means, in order.
    func change(_ next: LensPlayerProperties) -> [PlaybackReport] {
        let before = properties
        properties = next
        settleUrgency()
        // Entered first, so the events this change brings report it.
        let preloaded = preloading()
        let events = [
            bitrateEvent(before, next),
            muteEvent(before, next),
            // The spec's pr event "only triggers while the state is playing".
            state == .playing ? rateEvent(before, next) : nil,
            visibilityEvent(),
            presentationEvent(before, next),
        ]
        return preloaded + events.compactMap { $0 }.map { PlaybackReport(event: $0, state: state) }
    }

    /// The app went to the background or came back: `b` when that flips what the user can see.
    func page(hidden appHidden: Bool) -> [PlaybackReport] {
        self.appHidden = appHidden
        return visibilityEvent().map { [PlaybackReport(event: $0, state: state)] } ?? []
    }

    // MARK: What the session reads

    /// `st` as the player currently knows it.
    func streamType() -> StreamType? {
        if properties.live == true {
            return properties.lowLatency == true ? .lowLatencyLive : .live
        }
        return properties.live == false ? .vod : nil
    }

    /// What the player can do on this device: the claims Lens detects, overridden field by field by the adapter's.
    func capabilities() -> LensPlayerCapabilities {
        var result = Capabilities.platform()
        if let reported = snapshot?.capabilities {
            if let dolbyVision = reported.dolbyVision { result.dolbyVision = dolbyVision }
            if let codecs = reported.dolbyAudioCodecs { result.dolbyAudioCodecs = codecs }
        }
        return result
    }

    /// The keys every report of this session carries, for a report at `at` describing `state`.
    func status(_ state: PlayerState?, at: Double) -> StatusKeys {
        var keys = StatusKeys()
        keys.merge(playheadKeys(state, at: at))
        keys.merge(rateKeys(state))
        keys.merge(bufferKeys(state, at: at))
        keys.merge(bitrateKeys(properties.tracks))
        keys.merge(throughputKeys())
        keys.merge(droppedFrameKeys())
        if hidden(properties, appHidden) == true { keys[.backgrounded] = .flag(true) }
        if properties.nonRendered == true { keys[.nonRendered] = .flag(true) }
        return keys
    }

    // MARK: Report keys, one concern each

    private var playbackRate: Double { measured(properties.playbackRate) ?? 1 }

    /// `pt` from the last snapshot, moved on by the time since while playing;
    /// on a live stream with a program date time, epoch ms and `ltc` from it.
    private func playheadKeys(_ state: PlayerState?, at: Double) -> StatusKeys {
        var keys = StatusKeys()
        let moving = state == .playing && snapshot?.paused == false
        let elapsed = moving ? max(at - snapshotAt, 0) * playbackRate : 0
        let dateTime = measured(snapshot?.playheadDateTime.map { $0.timeIntervalSince1970 * 1000 })
        if properties.live == true, let dateTime {
            let playhead = dateTime + elapsed
            let latency = at - playhead
            keys[.playheadTime] = .number(jsRound(playhead))
            if latency >= 0 && latency <= maxLatencyMs {
                keys[.latency] = .number(jsRound(latency))
            }
        } else if let time = measured(snapshot?.currentTime) {
            keys[.playheadTime] = .number(jsRound(time * 1000 + elapsed))
        }
        return keys
    }

    /// `pr`: "1.0 if real-time, 2.0 if double speed, 0 if not playing" — sent only when not 1.
    private func rateKeys(_ state: PlayerState?) -> StatusKeys {
        var keys = StatusKeys()
        if state != .playing {
            keys[.playbackRate] = .number(0)
        } else if playbackRate != 1 {
            keys[.playbackRate] = .number(jsRound(playbackRate * 1000) / 1000)
        }
        return keys
    }

    /// `su`, the starvation keys, `bl` and `tbl`.
    private func bufferKeys(_ state: PlayerState?, at: Double) -> StatusKeys {
        var keys = StatusKeys()
        if startupUrgent(state) { keys[.startup] = .flag(true) }
        if state == .rebuffering { keys[.bufferStarvation] = .flag(true) }
        if starvations > 0 {
            keys[.bufferStarvationAbsolute] = .list([InnerListItem(Double(starvations))])
        }
        let starved = starvedMs + (rebufferFrom.map { at - $0 } ?? 0)
        if starved > 0 {
            keys[.bufferStarvationDurationAbsolute] = .list([InnerListItem(jsRound(starved))])
        }
        if let bl = bufferLength() { keys[.bufferLength] = .list(bl) }
        if let target = measured(properties.targetBuffer) {
            keys[.targetBufferLength] = .list([InnerListItem(rounded(target * 1000, 100))])
        }
        return keys
    }

    private func throughputKeys() -> StatusKeys {
        var keys = StatusKeys()
        if let throughput = measured(snapshot?.measuredThroughput) {
            keys[.measuredThroughput] = .list([InnerListItem(rounded(throughput / 1000, 100))])
        }
        return keys
    }

    /// `dfa`, counted from the session start: the adapter cannot know where sessions begin.
    private func droppedFrameKeys() -> StatusKeys {
        var keys = StatusKeys()
        if let last = droppedLast {
            keys[.droppedFramesAbsolute] = .number(max(droppedOffset + last - droppedBase, 0))
        }
        return keys
    }

    private func bufferLength() -> [InnerListItem]? {
        guard let snapshot, let time = measured(snapshot.currentTime),
            let buffered = snapshot.buffered
        else { return nil }
        if let whole = buffered.first(where: { $0.kind == nil }) {
            return bufferAhead(whole.ranges, time).map { [InnerListItem(rounded($0, 100))] }
        }
        var list: [InnerListItem] = []
        for (kind, ot) in mediaKinds {
            if let ahead = bufferAhead(buffered.first { $0.kind == kind }?.ranges, time) {
                list.append(InnerListItem(rounded(ahead, 100), ot: ot))
            }
        }
        return list.isEmpty ? nil : list
    }

    /// `su`: "true until its buffer first reaches the target buffer for stable
    /// playback" after a startup, seek or rebuffer. Without a way to tell, the
    /// startup, seeking and rebuffering states themselves are the window.
    private func startupUrgent(_ state: PlayerState?) -> Bool {
        bufferIsStable() == nil ? opensUrgency(state) : urgent
    }

    /// The adapter's `bufferStable`, else the buffered media against the target; unknown without either.
    private func bufferIsStable() -> Bool? {
        if let reported = properties.bufferStable { return reported }
        guard let bl = bufferLength(), let target = measured(properties.targetBuffer) else {
            return nil
        }
        return bl.allSatisfy { $0.value >= target * 1000 }
    }

    /// `d`: "loading, or has loaded, assets ahead of starting" — media held
    /// before any state, so before playback was requested. Read from what the
    /// player holds, never from its preload setting.
    private func preloading(snapshotCounts: Bool = true) -> [PlaybackReport] {
        state == nil && holdsMedia(snapshotCounts: snapshotCounts) ? enter(.preloading) : []
    }

    /// The pushed `hasMediaData`; without it, buffered media in the last
    /// snapshot, which Lens only reads at a fact — the push is what tells it
    /// at once.
    private func holdsMedia(snapshotCounts: Bool) -> Bool {
        if let pushed = properties.hasMediaData { return pushed }
        guard snapshotCounts, let buffered = snapshot?.buffered else { return false }
        return buffered.contains { entry in
            entry.ranges.contains {
                measured($0.start) != nil && measured($0.end) != nil && $0.end > $0.start
            }
        }
    }

    /// Closes the `su` window once the buffer is stable — and opens it when
    /// the buffer turns out not to be during a startup, seek or rebuffer that
    /// began on a stale "stable": an adapter may push the drop just after the
    /// fact that caused it. Once closed, it stays closed until the next one.
    private func settleUrgency() {
        let stable = bufferIsStable()
        if stable == true && urgent {
            urgent = false
            urgentSpent = true
        } else if stable == false && !urgent && !urgentSpent && opensUrgency(state) {
            urgent = true
        }
    }

    // MARK: State changes

    /// `b` when what the user can see flips against what was last known.
    private func visibilityEvent() -> CmcdEvent? {
        guard let isHidden = hidden(properties, appHidden) else { return nil }
        let flipped = wasHidden != nil && isHidden != wasHidden
        wasHidden = isHidden
        return flipped ? .backgroundChange : nil
    }

    /// One `ps` report for a state change, with the keys that leaving and entering states carry once.
    private func enter(_ next: PlayerState) -> [PlaybackReport] {
        let previous = state
        if next == previous { return [] }
        let now = self.now()
        var keys = StatusKeys()
        // The first state on a source: `dfa` counts from here, as nothing was rendered before.
        if previous == nil { droppedBase = droppedOffset + (droppedLast ?? 0) }
        if previous == .rebuffering, let from = rebufferFrom {
            let duration = jsRound(now - from)
            starvedMs += duration
            rebufferFrom = nil
            // The report that ends a starvation carries its duration, once.
            keys[.bufferStarvation] = .flag(true)
            keys[.bufferStarvationDuration] = .list([InnerListItem(duration)])
        }
        if next == .rebuffering {
            starvations += 1
            rebufferFrom = now
        }
        if next == .starting { startupFrom = now }
        if opensUrgency(next) {
            urgent = bufferIsStable() != true
            urgentSpent = false
        }
        if next == .playing && !startupReported, let from = startupFrom {
            keys[.mediaStartDelay] = .number(jsRound(now - from))
            startupReported = true
        }
        state = next
        return [
            PlaybackReport(event: .playStateChange, state: next, keys: keys.isEmpty ? nil : keys)
        ]
    }
}
