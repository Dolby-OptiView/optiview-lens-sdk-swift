import Foundation

/// The CMCD wire format — the only place the reverse-DNS prefix exists;
/// custom values are bent to the spec's shape here. Mechanics: docs/internals.md.
internal struct CmcdEncoder: ReportEncoder {
    let contentType = "application/cmcd"

    func encode(_ reports: [[(String, Any)]]) -> String {
        reports.map(encodeReport).joined(separator: "\n")
    }

    private func encodeReport(_ report: [(String, Any)]) -> String {
        let wire =
            report
            .map { (Encoding.specKeys.contains($0.0) ? $0.0 : Encoding.wirePrefix + $0.0, $0.1) }
            .sorted { $0.0 < $1.0 }
        return wire.map { key, value -> String in
            if key == "e" { return "\(key)=\(value)" }  // event type is a spec token, never quoted
            if Encoding.specKeys.contains(key) {
                guard let text = value as? String else { return "\(key)=\(value)" }
                return "\(key)=\"\(escape(text))\""
            }
            return customPair(key, value)
        }.joined(separator: ",")
    }

    /// Custom values MUST be STRING or TOKEN (CTA-5004-B): booleans ride as
    /// the bare tokens `true`/`false`; everything else — numbers included —
    /// as a sanitized, truncated sf-string.
    private func customPair(_ key: String, _ value: Any) -> String {
        if let flag = value as? Bool { return "\(key)=\(flag ? "true" : "false")" }
        let text = Encoding.sanitizeAndTruncate(Encoding.numberText(value), maxUnits: 64)
        return "\(key)=\"\(escape(text))\""
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
            of: "\"", with: "\\\"")
    }
}
