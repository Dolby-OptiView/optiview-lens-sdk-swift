import Foundation

/// What a player's source means for the session: whether it names media at
/// all, whether it is the media already playing, and the `cid`, `sf` and
/// `h` it yields. PlayerObserver decides sessions with these.

/// The session context a source yields.
internal struct SourceContext {
    let contentId: String?
    let streamingFormat: StreamFormat?
    let hostname: String?
}

private let hostPattern = try! NSRegularExpression(
    pattern: "^[a-z][a-z\\d+.-]*://(?:[^/?#]*@)?(\\[[^\\]]*\\]|[^/?#:@]+)",
    options: .caseInsensitive)

private let userInfoPattern = try! NSRegularExpression(
    pattern: "^([a-z][a-z\\d+.-]*://)[^/]*@", options: .caseInsensitive)

private func isPrintableAscii(_ value: String) -> Bool {
    !value.isEmpty && value.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
}

/// The URL up to its query or fragment.
private func withoutQuery(_ url: String) -> String {
    String(String.UnicodeScalarView(url.unicodeScalars.prefix { $0 != "?" && $0 != "#" }))
}

/// Everything outside printable ASCII percent-encoded, as `encodeURIComponent` does.
private func percentEncoded(_ value: String) -> String {
    var out = ""
    for scalar in value.unicodeScalars {
        if (0x20...0x7E).contains(scalar.value) {
            out.unicodeScalars.append(scalar)
        } else {
            for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
        }
    }
    return out
}

/// `sf` from the MIME type, else from the manifest's file extension; unknown stays unknown.
private func streamingFormat(_ source: LensPlayerSource) -> StreamFormat? {
    let mime = source.mimeType?.lowercased() ?? ""
    if mime.contains("mpegurl") { return .hls }
    if mime.contains("dash+xml") { return .mpegDash }
    if mime.contains("vnd.ms-sstr") { return .smoothStreaming }
    if mime.contains("hesp") { return .hesp }
    if !mime.isEmpty { return .other }
    let path = withoutQuery(source.url ?? "").lowercased()
    if path.hasSuffix(".m3u8") { return .hls }
    if path.hasSuffix(".mpd") { return .mpegDash }
    if path.range(of: "\\.ism[lc]?/manifest$", options: .regularExpression) != nil {
        return .smoothStreaming
    }
    return nil
}

/// The source's session context: the integrator's `cid` or one derived from
/// the URL without query and fragment. A fallback (`continuation`) plays the
/// same content, so there only a content ID the source names changes `cid`.
internal func sourceContext(_ source: LensPlayerSource, continuation: Bool = false)
    -> SourceContext
{
    let url = source.url ?? ""
    let host = hostPattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url))
        .flatMap { Range($0.range(at: 1), in: url) }
        .map { url[$0].lowercased() }
    // Credentials in the URL never reach the wire: the user info goes with the query.
    let bare = withoutQuery(url)
    let path = percentEncoded(
        userInfoPattern.stringByReplacingMatches(
            in: bare, range: NSRange(bare.startIndex..., in: bare), withTemplate: "$1"))
    // Percent-encoded, the path is ASCII: one UTF-16 unit per character.
    let derived = path.isEmpty ? nil : String(path.prefix(128))
    let given = source.contentId.flatMap {
        Validation.checkedContentId($0, strict: false).contentId
    }
    return SourceContext(
        contentId: continuation ? given : (given ?? derived),
        streamingFormat: streamingFormat(source),
        hostname: host.flatMap { $0.utf16.count <= 128 && isPrintableAscii($0) ? $0 : nil }
    )
}

/// A source Lens can use, named by a URL or a content ID, or nil for none or something unusable.
internal func usableSource(_ source: LensPlayerSource?) -> LensPlayerSource? {
    guard let source else { return nil }
    return source.url?.isEmpty == false || source.contentId?.isEmpty == false ? source : nil
}

/// Whether two sources name the same media: the same URL and the same content ID.
internal func sameSource(_ a: LensPlayerSource?, _ b: LensPlayerSource?) -> Bool {
    a?.url == b?.url && a?.contentId == b?.contentId
}
