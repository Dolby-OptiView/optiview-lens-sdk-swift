import Foundation

/// The JSON wire format — the reports exactly as assembled; the fidelity
/// path, byte-identical to the web reference. Mechanics: docs/internals.md.
internal struct JsonEncoder: ReportEncoder {
    let contentType = "application/json"

    func encode(_ reports: [[(String, Any)]]) -> String {
        "{\"reports\":[" + reports.map(encodeReport).joined(separator: ",") + "]}"
    }

    private func encodeReport(_ report: [(String, Any)]) -> String {
        let fields = report.map { key, value -> String in
            let encoded: String
            if let flag = value as? Bool {
                encoded = flag ? "true" : "false"
            } else if let token = value as? LensToken {
                encoded = "\"\(escape(token.value))\""
            } else if let text = value as? String {
                encoded = "\"\(escape(text))\""
            } else {
                encoded = Encoding.numberText(value)
            }
            return "\"\(escape(key))\":\(encoded)"
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private func escape(_ value: String) -> String {
        var out = ""
        for ch in value.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 {
                    out += String(format: "\\u%04x", ch.value)
                } else {
                    out.unicodeScalars.append(ch)
                }
            }
        }
        return out
    }
}
