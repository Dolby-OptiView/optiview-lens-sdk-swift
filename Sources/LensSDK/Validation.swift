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

    /// Custom key names: lowercase-letter-first tokens within the wire-key budget (docs/internals.md).
    static let keyPattern = "^[a-z][a-z0-9-]*$"
    static let keyMax = 64 - Encoding.wirePrefix.count // becomes per-producer when customer prefixes land (#14)

    /// Custom event names: simple tokens, max 64 chars (the spec's cen budget).
    static let namePattern = "^[A-Za-z0-9_-]+$"
    static let nameMax = 64

    /// Setup strings (namespace, external session ids): printable ASCII, max 64 (the spec's sid budget).
    static let setupPattern = "^[\\x20-\\x7E]{1,64}$"

    static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
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
    /// the offending key is dropped with a warning. Values pass through
    /// untouched. Returns nil keys plus drop=true when a strict violation's
    /// swapped test handler returns — mirroring a throw.
    static func checkedCustomKeys(_ custom: LensEventKeys?, strict: Bool) -> (keys: LensEventKeys?, drop: Bool) {
        guard let custom else { return (nil, false) }
        var clean: LensEventKeys = [:]
        for (key, value) in custom {
            let problem: String?
            if cmcdReserved.contains(key) {
                problem = "Lens: '\(key)' is a registered CMCD key and cannot be a custom key"
            } else if !matches(key, keyPattern) {
                problem = "Lens: invalid custom key '\(key)' — lowercase letter first, then lowercase letters, digits, hyphens"
            } else if key.count > keyMax {
                problem = "Lens: custom key '\(key)' exceeds \(keyMax) characters (the spec's 64 minus the wire prefix)"
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

    /// True when the event may be sent; reports the violation otherwise.
    static func checkedCustomEventName(_ name: String, strict: Bool) -> Bool {
        guard matches(name, namePattern) else {
            violation("Lens: invalid custom event name '\(name)' — letters, digits, hyphens, underscores", strict: strict)
            return false
        }
        guard name.count <= nameMax else {
            violation("Lens: custom event name '\(name)' exceeds \(nameMax) characters", strict: strict)
            return false
        }
        return true
    }
}
