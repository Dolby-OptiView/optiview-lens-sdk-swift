import XCTest

@testable import LensSDK

/// Detection is compile-time on Apple platforms, so the assertions are about
/// the build this test runs in — the dev host that `swift test` uses, and the
/// simulators CI runs after it.
final class EnvironmentTests: XCTestCase {
    func testPlatformTokenMatchesTheBuild() {
        let environment = EnvironmentRuntime.current()
        #if os(tvOS)
            XCTAssertEqual(environment.p, "tvos")
            XCTAssertEqual(environment.dc, "tv")
        #else
            XCTAssertEqual(
                environment.p, "ios", "a host build reports the platform the package ships for")
        #endif
    }

    func testOsIsReportedWhereverTheSystemStatesIt() {
        let environment = EnvironmentRuntime.current()
        #if canImport(UIKit)
            XCTAssertFalse(environment.os!.isEmpty)
            XCTAssertFalse(environment.osv!.isEmpty)
        #endif
        XCTAssertNil(environment.bn, "browser keys are web-only")
        XCTAssertNil(environment.bv, "browser keys are web-only")
    }
}
