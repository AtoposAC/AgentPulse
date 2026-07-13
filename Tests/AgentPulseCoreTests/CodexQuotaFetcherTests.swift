import Foundation
import XCTest
@testable import AgentPulseCore

final class CodexQuotaFetcherTests: XCTestCase {
    func testWeeklyPrimaryWindowIsNotClassifiedAsFiveHourQuota() throws {
        let snapshot = try CodexQuotaFetcher.parseSnapshot(data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 5,
              "reset_at": 1784534400,
              "limit_window_seconds": 604800
            }
          }
        }
        """))

        XCTAssertNil(snapshot.quota5hRemainingPercent)
        XCTAssertNil(snapshot.quota5hResetAt)
        XCTAssertEqual(snapshot.quotaWeekRemainingPercent, 95)
        XCTAssertEqual(snapshot.quotaWeekWindowSeconds, 604800)
    }

    func testTraditionalPrimaryAndSecondaryWindowsRemainClassifiedCorrectly() throws {
        let snapshot = try CodexQuotaFetcher.parseSnapshot(data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 44,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 62,
              "limit_window_seconds": 604800
            }
          }
        }
        """))

        XCTAssertEqual(snapshot.quota5hRemainingPercent, 56)
        XCTAssertEqual(snapshot.quota5hWindowSeconds, 18000)
        XCTAssertEqual(snapshot.quotaWeekRemainingPercent, 38)
        XCTAssertEqual(snapshot.quotaWeekWindowSeconds, 604800)
    }

    func testSingleAmbiguousPrimaryWindowIsNotAssignedToEitherQuota() throws {
        let snapshot = try CodexQuotaFetcher.parseSnapshot(data("""
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 5
            }
          }
        }
        """))

        XCTAssertNil(snapshot.quota5hRemainingPercent)
        XCTAssertNil(snapshot.quotaWeekRemainingPercent)
    }

    private func data(_ json: String) -> Data {
        Data(json.utf8)
    }
}
