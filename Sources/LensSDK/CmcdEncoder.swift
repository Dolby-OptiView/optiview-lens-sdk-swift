import Foundation

/// The CMCD wire format — the only place the reverse-DNS prefix exists;
/// custom values are bent to the spec's shape here. Mechanics: docs/internals.md.
internal struct CmcdEncoder: ReportEncoder {
    private static let stringMax = 64
    private static let maxTrackedSids = 64
    private static let warningState = WarningState()

    private final class WarningState {
        private let lock = NSLock()
        private var warnedStringKeysBySession: [(sid: String, keys: Set<String>)] = []

        func shouldWarn(sessionId: String, key: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if let index = warnedStringKeysBySession.firstIndex(where: { $0.sid == sessionId }) {
                var entry = warnedStringKeysBySession[index]
                let inserted = entry.keys.insert(key).inserted
                warnedStringKeysBySession[index] = entry
                return inserted
            }
            warnedStringKeysBySession.append((sid: sessionId, keys: [key]))
            if warnedStringKeysBySession.count > CmcdEncoder.maxTrackedSids {
                warnedStringKeysBySession.removeFirst()
            }
            return true
        }
    }

    let contentType = "application/cmcd"

    func encode(_ reports: [[(String, Any)]]) -> String {
        reports.map(encodeReport).joined(separator: "\n")
    }

    private func encodeReport(_ report: [(String, Any)]) -> String {
        let wire =
            report
            .map {
                (
                    short: $0.0,
                    key: Encoding.specKeys.contains($0.0) ? $0.0 : Encoding.wirePrefix + $0.0,
                    value: $0.1
                )
            }
            .sorted { $0.key < $1.key }
        let sessionId = report.first { $0.0 == "sid" }?.1 as? String ?? ""
        return wire.compactMap { short, key, value -> String? in
            // spec tokens, never quoted
            if Encoding.tokenKeys.contains(key) { return "\(key)=\(value)" }
            if Encoding.specKeys.contains(key) { return specPair(key, value) }
            // Lens-owned token vocabularies ride bare too
            if Encoding.lensTokenKeys.contains(short) { return "\(key)=\(value)" }
            return customPair(key, short, sessionId, value)
        }.joined(separator: ",")
    }

    /// Registered keys as the spec types them, matching CML on web: inner
    /// lists as `(4200;v 256;a)`, a true boolean bare and a false one omitted,
    /// string lists as `("a" "b")`, strings quoted.
    private func specPair(_ key: String, _ value: Any) -> String? {
        switch value {
        case let flag as Bool:
            return flag ? key : nil
        case let text as String:
            return "\(key)=\"\(escape(text))\""
        case let items as [InnerListItem]:
            let members = items.map { item in
                Encoding.numberText(item.value) + (item.ot.map { ";\($0)" } ?? "")
            }
            return "\(key)=(\(members.joined(separator: " ")))"
        case let strings as [String]:
            return "\(key)=(\(strings.map { "\"\(escape($0))\"" }.joined(separator: " ")))"
        default:
            return "\(key)=\(Encoding.numberText(value))"
        }
    }

    /// Custom values MUST be STRING or TOKEN (CTA-5004-B): booleans and
    /// explicit tokens ride bare; ordinary strings and numbers use a
    /// sanitized, truncated sf-string.
    private func customPair(
        _ key: String,
        _ shortKey: String,
        _ sessionId: String,
        _ value: Any
    ) -> String {
        if let flag = value as? Bool { return "\(key)=\(flag ? "true" : "false")" }
        if let token = value as? LensToken {
            return "\(key)=\(token.value)"
        }
        let sanitized = Encoding.sanitize(Encoding.numberText(value))
        if value is String, sanitized.utf16.count > Self.stringMax,
            Self.warningState.shouldWarn(sessionId: sessionId, key: shortKey)
        {
            Lens.warn(
                "Lens: custom value for '\(shortKey)' exceeds \(Self.stringMax) UTF-16 units and is truncated on the CMCD wire"
            )
        }
        let text = Encoding.sanitizeAndTruncate(sanitized, maxUnits: Self.stringMax)
        return "\(key)=\"\(escape(text))\""
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
            of: "\"", with: "\\\"")
    }
}
