import Foundation

/// The CMCD wire format — the only place the reverse-DNS prefix exists;
/// custom values are bent to the spec's shape here. Mechanics: docs/internals.md.
internal struct CmcdEncoder: ReportEncoder {
    let contentType = "application/cmcd"

    func encode(_ reports: [[(String, Any)]]) -> String {
        reports.map(encodeReport).joined(separator: "\n")
    }

    private func encodeReport(_ report: [(String, Any)]) -> String {
        let wire = report
            .map { (Encoding.specKeys.contains($0.0) ? $0.0 : Encoding.wirePrefix + $0.0, $0.1) }
            .sorted { $0.0 < $1.0 }
        return wire.map { key, value -> String in
            if key == "e" { return "\(key)=\(value)" } // event type is a spec token, never quoted
            let isSpec = Encoding.specKeys.contains(key)
            if isSpec, !(value is String) { return "\(key)=\(value)" }
            var text = (value as? Bool).map { $0 ? "true" : "false" } ?? Encoding.numberText(value)
            if !isSpec { text = Encoding.sanitizeAndTruncate(text, maxUnits: 64) }
            return "\(key)=\"\(escape(text))\""
        }.joined(separator: ",")
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
