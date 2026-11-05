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
            "\"\(escape(key))\":\(encodeValue(value))"
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// An inner list is an array of `{ value, ot }`, `ot` absent when unsplit.
    private func encodeValue(_ value: Any) -> String {
        switch value {
        case let flag as Bool:
            return flag ? "true" : "false"
        case let token as LensToken:
            return "\"\(escape(token.value))\""
        case let text as String:
            return "\"\(escape(text))\""
        case let items as [InnerListItem]:
            let members = items.map { item in
                "{\"value\":\(Encoding.numberText(item.value))"
                    + (item.ot.map { ",\"ot\":\"\(escape($0))\"" } ?? "") + "}"
            }
            return "[" + members.joined(separator: ",") + "]"
        case let strings as [String]:
            return "[" + strings.map { "\"\(escape($0))\"" }.joined(separator: ",") + "]"
        default:
            return Encoding.numberText(value)
        }
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
