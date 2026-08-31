import Foundation

/// The canonical vocabulary contract — destination-independent by ruling;
/// names fail here, values bend in the encoder. Rules and rationale:
/// docs/internals.md.
internal enum Validation {
    /// The registered CMCD names (CTA-5004-B) plus "ns" — never custom keys (docs/internals.md).
    static let cmcdReserved: Set<String> = [
        "ab", "bg", "bl", "br", "bs", "bsa", "bsd", "bsda", "cdn", "cen", "cid",
        "cmsdd", "cmsds", "cs", "d", "dfa", "dl", "e", "ec", "h", "lab", "lb",
        "ltc", "msd", "mtp", "nor", "nr", "nrr", "ns", "ot", "pb", "pr", "pt", "rc",
        "rtp", "sf", "sid", "smrt", "sn", "st", "sta", "su", "tab", "tb", "tbl",
        "tpb", "ts", "ttfb", "ttfbb", "ttlb", "url", "v",
    ]

    /// Keys Lens stamps itself — the environment plus the user ID (docs/internals.md).
    static let lensReserved = Set(EnvironmentRuntime.environmentKeys + ["u"])

    /// Custom key names: lowercase-letter-first tokens within the wire-key budget
    /// (docs/internals.md).
    static let keyPattern = "^[a-z][a-z0-9_]*$"
    // Becomes per-producer when customer prefixes land (#14).
    static let keyMax = 64 - Encoding.wirePrefix.count

    /// Custom event names: simple tokens, max 64 chars (the spec's cen budget).
    static let namePattern = "^[A-Za-z0-9_-]+$"
    static let nameMax = 64

    /// Setup strings (namespace, external session ids): printable ASCII, max 64 (the spec's sid budget).
    static let setupPattern = "^[\\x20-\\x7E]{1,64}$"

    /// RFC 8941 sf-token grammar for explicit custom token values.
    static let tokenPattern = "\\A[A-Za-z*][A-Za-z0-9!#$%&'*+\\-.^_`|~:/]*\\z"
    static let tokenMax = 64

    /// Content IDs (spec `cid`): printable ASCII, max 128 (the spec's raised cid budget).
    static let contentIdPattern = "^[\\x20-\\x7E]{1,128}$"

    /// Streaming format (`sf`) tokens (CTA-5004-B Table 1).
    static let sfTokens: Set<String> = ["d", "h", "s", "e", "o"]

    /// Stream type (`st`) tokens (CTA-5004-B Table 1).
    static let stTokens: Set<String> = ["v", "l", "ll"]

    /// Reserved for reports the SDK would send on its own behalf — no integrator may claim it.
    static let lensNamespace = "lens"

    /// The spec's default interval-report cadence (CTA-5004-B Table 1).
    static let defaultHeartbeatMs: Int64 = 30_000

    /// Below this a heartbeat is a flood, not a liveness signal.
    static let minHeartbeatMs: Int64 = 1_000

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    static func isValidToken(_ value: String) -> Bool {
        matches(value, tokenPattern)
    }

    /// One choke point for emit-path violations: strict fails, default warns and drops.
    static func violation(_ message: String, strict: Bool) {
        if strict {
            Lens.usageViolation(message)
        } else {
            print("[Lens] \(message)")
        }
    }

    /// Name problems are contract violations: strict mode fails; by default
    /// the offending key is dropped with a warning. Ordinary values pass
    /// through untouched; explicit token values are grammar-checked. Returns
    /// nil keys plus drop=true when a strict violation's swapped test handler
    /// returns — mirroring a throw.
    static func checkedCustomKeys(_ custom: LensEventKeys?, strict: Bool) -> (
        keys: LensEventKeys?, drop: Bool
    ) {
        guard let custom else { return (nil, false) }
        var clean: LensEventKeys = [:]
        for (key, value) in custom {
            let problem: String?
            if cmcdReserved.contains(key) {
                problem = "Lens: '\(key)' is a registered CMCD key and cannot be a custom key"
            } else if lensReserved.contains(key) {
                problem = "Lens: '\(key)' is a Lens-owned key and cannot be a custom key"
            } else if !matches(key, keyPattern) {
                problem =
                    "Lens: invalid custom key '\(key)' — lowercase letter first, then lowercase letters, digits, underscores"
            } else if key.count > keyMax {
                problem =
                    "Lens: custom key '\(key)' exceeds \(keyMax) characters (the spec's 64 minus the wire prefix)"
            } else if isNonFiniteNumber(value) {
                problem = "Lens: custom key '\(key)' has a non-finite value (NaN or Infinity)"
            } else if let token = value as? LensToken, !isValidToken(token.value) {
                problem =
                    "Lens: invalid custom token value '\(token.value)' — must match the RFC 8941 sf-token grammar"
            } else if let token = value as? LensToken, token.value.utf16.count > tokenMax {
                problem = "Lens: custom token value exceeds \(tokenMax) UTF-16 units"
            } else {
                problem = nil
            }
            if let problem {
                violation(problem, strict: strict)
                if strict { return (nil, true) }
            } else {
                clean[key] = value
            }
        }
        return (clean.isEmpty ? nil : clean, false)
    }

    /// Ad content IDs arrive on the emit path: strict fails (dropping the
    /// event, mirroring a throw), default warns and drops only the field.
    static func checkedContentId(_ value: String?, strict: Bool) -> (
        contentId: String?, drop: Bool
    ) {
        guard let value else { return (nil, false) }
        if matches(value, contentIdPattern) { return (value, false) }
        violation("Lens: contentId must be 1-128 printable ASCII characters", strict: strict)
        return (nil, strict)
    }

    /// True when the event may be sent; reports the violation otherwise.
    static func checkedCustomEventName(_ name: String, strict: Bool) -> Bool {
        guard matches(name, namePattern) else {
            violation(
                "Lens: invalid custom event name '\(name)' — letters, digits, hyphens, underscores",
                strict: strict)
            return false
        }
        guard name.count <= nameMax else {
            violation(
                "Lens: custom event name '\(name)' exceeds \(nameMax) characters", strict: strict)
            return false
        }
        return true
    }
}
