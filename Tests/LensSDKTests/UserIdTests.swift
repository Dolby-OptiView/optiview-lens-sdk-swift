import XCTest

@testable import LensSDK

final class UserIdTests: XCTestCase {
    private let uuidPattern =
        "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"

    override func tearDown() {
        UserIdRuntime.resetForTesting()
        Lens.resetConfigurationForTesting()
        super.tearDown()
    }

    func testGeneratesOneUuidAndReturnsItOnEveryCall() {
        let first = UserIdRuntime.currentUserId()
        XCTAssertNotNil(first.range(of: uuidPattern, options: .regularExpression))
        XCTAssertEqual(first, UserIdRuntime.currentUserId())
    }

    func testPersistsInUserDefaultsAcrossRuns() {
        let first = UserIdRuntime.currentUserId()
        // A new run: the in-memory value is gone, UserDefaults survives.
        UserIdRuntime.resetForTesting()
        UserDefaults.standard.set(first, forKey: "com.dolby.optiview.lens.u")
        XCTAssertEqual(first, UserIdRuntime.currentUserId())
    }

    func testReplacesATamperedStoredValueInsteadOfStampingIt() {
        UserDefaults.standard.set("not-a-uuid; drop table", forKey: "com.dolby.optiview.lens.u")
        let id = UserIdRuntime.currentUserId()
        XCTAssertNotNil(id.range(of: uuidPattern, options: .regularExpression))
        XCTAssertEqual(id, UserDefaults.standard.string(forKey: "com.dolby.optiview.lens.u"))
    }

    func testConsentDenialDeletesTheIdAndTheNextReportGetsAFreshOne() throws {
        let before = UserIdRuntime.currentUserId()
        let lens = try Lens.join(LensJoinOptions(namespace: "ads", heartbeatMs: 0))
        lens.setConsent(.denied)
        XCTAssertNil(UserDefaults.standard.string(forKey: "com.dolby.optiview.lens.u"))
        XCTAssertNotEqual(before, UserIdRuntime.currentUserId())
    }
}
