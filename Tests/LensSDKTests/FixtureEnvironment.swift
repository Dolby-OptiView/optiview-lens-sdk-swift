@testable import LensSDK

/// The environment a conformance fixture was generated with, so replays match byte for byte.
internal enum FixtureEnvironment {
    static func parse(_ raw: [String: Any]) -> LensEnvironment {
        var environment = LensEnvironment(p: raw["p"] as! String)
        environment.os = raw["os"] as? String
        environment.osv = raw["osv"] as? String
        environment.bn = raw["bn"] as? String
        environment.bv = raw["bv"] as? String
        environment.dc = raw["dc"] as? String
        return environment
    }
}
