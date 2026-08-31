import Foundation

internal func isNonFiniteNumber(_ value: Any) -> Bool {
    if value is Bool { return false }
    if let double = value as? Double { return !double.isFinite }
    if let float = value as? Float { return !float.isFinite }
    if let cgFloat = value as? CGFloat { return !cgFloat.isFinite }
    if let number = value as? NSNumber { return !number.doubleValue.isFinite }
    return false
}

/// Report assembly and the encoder seam — one `ReportEncoder` per wire
/// format, each in its own file. Mechanics: docs/internals.md.
internal protocol ReportEncoder {
    var contentType: String { get }
    func encode(_ reports: [[(String, Any)]]) -> String
}

internal enum Encoding {
    /// The spec keys Lens stamps; everything else in a report is a custom key.
    static let specKeys: Set<String> = ["e", "cen", "ts", "sid", "sn", "v", "cid", "sf", "st"]

    /// Spec keys whose values are spec tokens, never quoted on the CMCD wire.
    static let tokenKeys: Set<String> = ["e", "sf", "st"]

    /// Lens-owned keys whose values are spec token vocabularies — bare on the CMCD wire.
    static let lensTokenKeys: Set<String> = ["p", "dc"]

    /// A token value travels as the registry's abbreviation, which ingest
    /// expands back to the full value (spec §2, §4.2). Mirrors `values` in
    /// `registry/keys/lens.json`, inverted; the vocabulary suite pins it there.
    static let tokenAbbreviations: [String: [String: String]] = [
        "p": ["web": "w", "android": "a", "ios": "i", "tvos": "tv"],
        "dc": ["desktop": "d", "mobile": "m", "tablet": "t", "tv": "tv"],
    ]

    private static func abbreviate(_ key: String, _ value: String) -> String {
        tokenAbbreviations[key]?[value] ?? value
    }

    static let wirePrefix = "com.dolby.optiview-"

    /// Replace control characters before they reach a structured field.
    static func sanitize(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            out.append((scalar.value < 0x20 || scalar.value == 0x7F) ? " " : scalar)
        }
        return String(out)
    }

    /// Truncate to a UTF-16 unit budget (how the ecosystem validator counts)
    /// on scalar boundaries only — a raw UTF-16 cut can split a surrogate
    /// pair.
    static func sanitizeAndTruncate(_ value: String, maxUnits: Int) -> String {
        let sanitized = sanitize(value)
        var units = 0
        var out = String.UnicodeScalarView()
        for scalar in sanitized.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if units + width > maxUnits { break }
            out.append(scalar)
            units += width
        }
        return String(out)
    }

    /// Whole doubles render as integers — matching the web reference ("2", not "2.0").
    static func numberText(_ value: Any) -> String {
        if let double = value as? Double, double.isFinite, double == double.rounded(),
            abs(double) < 1e15
        {
            return String(Int64(double))
        }
        return "\(value)"
    }

    /// The flat report: spec keys, the environment stamp, the user ID, then
    /// short custom names, sorted — the fixed golden order. The environment
    /// and user ID arrive as arguments so a fixture can supply them and the
    /// host never leaks into a golden.
    static func toReport(
        _ event: LensEvent, _ sn: Int, _ environment: LensEnvironment, _ userId: String
    )
        -> [(String, Any)]
    {
        var report: [(String, Any)] = [("e", event.type)]
        if let cen = event.customName { report.append(("cen", cen)) }
        report.append(("ts", event.timestamp))
        report.append(("sid", event.session.sessionId))
        if let cid = event.contentId { report.append(("cid", cid)) }
        if let sf = event.streamingFormat { report.append(("sf", sf)) }
        if let st = event.streamType { report.append(("st", st)) }
        report.append(("sn", sn))
        // event mode is v2; request mode will use v1 syntax — never share this builder
        report.append(("v", 2))
        report.append(("ns", event.namespace))
        // Sorted, and only what is known — an unknown value is omitted, never a placeholder.
        if let bn = environment.bn { report.append(("bn", bn)) }
        if let bv = environment.bv { report.append(("bv", bv)) }
        if let dc = environment.dc { report.append(("dc", abbreviate("dc", dc))) }
        if let os = environment.os { report.append(("os", os)) }
        if let osv = environment.osv { report.append(("osv", osv)) }
        report.append(("p", abbreviate("p", environment.p)))
        report.append(("u", userId))
        if let keys = event.keys {
            for key in keys.keys.sorted() { report.append((key, keys[key]!)) }
        }
        return report.filter { !isNonFiniteNumber($0.1) }
    }

    static func encoderFor(_ format: LensFormat) -> ReportEncoder {
        format == .json ? JsonEncoder() : CmcdEncoder()
    }

    /// One body per flush.
    static func encodeBody(_ format: LensFormat, _ reports: [[(String, Any)]]) -> (
        body: String, contentType: String
    ) {
        let encoder = encoderFor(format)
        return (encoder.encode(reports), encoder.contentType)
    }
}
