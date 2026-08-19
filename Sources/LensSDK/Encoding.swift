import Foundation

/// Report assembly and the encoder seam — one `ReportEncoder` per wire
/// format, each in its own file. Mechanics: docs/internals.md.
internal protocol ReportEncoder {
    var contentType: String { get }
    func encode(_ reports: [[(String, Any)]]) -> String
}

internal enum Encoding {
    /// The spec keys Lens stamps; everything else in a report is a custom key.
    static let specKeys: Set<String> = ["e", "cen", "ts", "sid", "sn", "v"]

    static let wirePrefix = "com.dolby.optiview-"

    /// Replace control characters (they can't ride a structured field and
    /// break newline batch framing), then truncate to a UTF-16 unit budget
    /// (how the ecosystem validator counts) on scalar boundaries only — a
    /// raw UTF-16 cut can split a surrogate pair.
    static func sanitizeAndTruncate(_ value: String, maxUnits: Int) -> String {
        var units = 0
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            let clean: Unicode.Scalar = (scalar.value < 0x20 || scalar.value == 0x7F) ? " " : scalar
            let width = clean.value > 0xFFFF ? 2 : 1
            if units + width > maxUnits { break }
            out.append(clean)
            units += width
        }
        return String(out)
    }

    /// Whole doubles render as integers — matching the web reference ("2", not "2.0").
    static func numberText(_ value: Any) -> String {
        if let double = value as? Double, double.isFinite, double == double.rounded(), abs(double) < 1e15 {
            return String(Int64(double))
        }
        return "\(value)"
    }

    /// The flat report: spec keys + short custom names, sorted — the fixed golden order.
    static func toReport(_ event: LensEvent, _ sn: Int) -> [(String, Any)] {
        var report: [(String, Any)] = [("e", event.type)]
        if let cen = event.customName { report.append(("cen", cen)) }
        report.append(("ts", event.timestamp))
        report.append(("sid", event.session.sessionId))
        report.append(("sn", sn))
        // event mode is v2; request mode will use v1 syntax — never share this builder
        report.append(("v", 2))
        report.append(("ns", event.namespace))
        if let keys = event.keys {
            for key in keys.keys.sorted() { report.append((key, keys[key]!)) }
        }
        return report
    }

    static func encoderFor(_ format: LensFormat) -> ReportEncoder {
        format == .json ? JsonEncoder() : CmcdEncoder()
    }

    /// One body per flush.
    static func encodeBody(_ format: LensFormat, _ reports: [[(String, Any)]]) -> (body: String, contentType: String) {
        let encoder = encoderFor(format)
        return (encoder.encode(reports), encoder.contentType)
    }
}
