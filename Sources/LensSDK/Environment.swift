import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// Where the report ran: platform, OS, device class. Detection is
/// deliberately basic — stated facts only, no fingerprinting. Keys and
/// rationale: docs/internals.md.
internal struct LensEnvironment {
    /// Platform token — the runtime that produced the report; always present.
    let p: String
    var os: String?
    var osv: String?
    var bn: String?
    var bv: String?
    var dc: String?
}

internal enum EnvironmentRuntime {
    /// The keys Lens stamps from the environment — reserved against integrator custom keys.
    static let environmentKeys = ["bn", "bv", "dc", "os", "osv", "p"]
    static let deviceClasses = (
        desktop: "desktop",
        mobile: "mobile",
        tablet: "tablet",
        tv: "tv"
    )

    /// Resolved once per process — none of it changes while the app lives.
    private static let detected: LensEnvironment = detect()

    static func current() -> LensEnvironment { override ?? detected }

    private static func detect() -> LensEnvironment {
        // Lens ships for iOS and tvOS only; a Mac Catalyst build is os(iOS) and
        // lands on 'ios', as it should. The package still builds for a dev host
        // (that is where `swift test` and the scenario app run), which reports
        // 'ios' rather than a platform token nobody agreed on — and a release
        // build for anything but the two shipping platforms refuses to compile,
        // so no such build can reach production.
        #if os(tvOS)
            var environment = LensEnvironment(p: "tvos")
        #elseif os(iOS) || DEBUG
            var environment = LensEnvironment(p: "ios")
        #else
            #error("The Lens SDK supports iOS and tvOS only.")
        #endif
        #if canImport(UIKit)
            let device = UIDevice.current
            environment.os = device.systemName
            environment.osv = device.systemVersion
            switch device.userInterfaceIdiom {
            case .phone: environment.dc = deviceClasses.mobile
            case .pad: environment.dc = deviceClasses.tablet
            case .tv: environment.dc = deviceClasses.tv
            default:
                if #available(iOS 14.0, tvOS 14.0, *), device.userInterfaceIdiom == .mac {
                    environment.dc = deviceClasses.desktop
                }
            }
        #endif
        return environment
    }

    // --- Test seams — not part of the production path ---

    static var override: LensEnvironment?
}
