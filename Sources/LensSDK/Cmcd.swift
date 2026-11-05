import Foundation

/// The CTA-5004-B vocabulary Lens reports, named as the data spec's registry
/// names it (`registry/keys/lens.json`, `registry/events/lens.json`); the
/// vocabulary suite pins both ways.

/// The CMCD keys Lens stamps itself; everything else in a report is a custom key.
internal enum CmcdKey: String, CaseIterable {
    case event = "e"
    case customEventName = "cen"
    case timestamp = "ts"
    case sessionId = "sid"
    case sequenceNumber = "sn"
    case version = "v"
    case contentId = "cid"
    case streamFormat = "sf"
    case streamType = "st"
    case hostname = "h"
    case state = "sta"
    case playheadTime = "pt"
    case playbackRate = "pr"
    case startup = "su"
    case mediaStartDelay = "msd"
    case bufferStarvation = "bs"
    case bufferStarvationAbsolute = "bsa"
    case bufferStarvationDuration = "bsd"
    case bufferStarvationDurationAbsolute = "bsda"
    case errorCodes = "ec"
    case bufferLength = "bl"
    case targetBufferLength = "tbl"
    case encodedBitrate = "br"
    case topBitrate = "tb"
    case lowestBitrate = "lb"
    case playheadBitrate = "pb"
    case aggregateBitrate = "ab"
    case topAggregateBitrate = "tab"
    case lowestAggregateBitrate = "lab"
    case measuredThroughput = "mtp"
    case latency = "ltc"
    case droppedFramesAbsolute = "dfa"
    case backgrounded = "bg"
    case nonRendered = "nr"
}

/// The events Lens reports on its own, in the `lens` namespace — plus `ce`, how custom events travel.
internal enum CmcdEvent: String, CaseIterable {
    case timeInterval = "t"
    case playStateChange = "ps"
    case contentIdChange = "c"
    case hostnameChange = "h"
    case error = "e"
    case bitrateChange = "bc"
    case mute = "m"
    case unmute = "um"
    case playbackRateChange = "pr"
    case backgroundChange = "b"
    case playerExpand = "pe"
    case playerCollapse = "pc"
    case customEvent = "ce"
}

/// `sta`. `quit` is only ever the session end's, never a state a player is in.
internal enum PlayerState: String, CaseIterable {
    case starting = "s"
    case playing = "p"
    case seeking = "k"
    case rebuffering = "r"
    case paused = "a"
    case waiting = "w"
    case ended = "e"
    case fatal = "f"
    case quit = "q"
    case preloading = "d"
}

/// `sf`.
internal enum StreamFormat: String, CaseIterable {
    case mpegDash = "d"
    case hls = "h"
    case hesp = "e"
    case smoothStreaming = "s"
    case other = "o"
}

/// `st`.
internal enum StreamType: String, CaseIterable {
    case vod = "v"
    case live = "l"
    case lowLatencyLive = "ll"
}
