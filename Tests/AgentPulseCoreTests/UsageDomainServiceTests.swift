import Foundation
import XCTest
@testable import AgentPulseCore

final class UsageDomainServiceTests: XCTestCase {
    func testNestedAutoReviewMergesIntoParentWorkSegment() {
        let parent = journalEntry(
            start: "2026-07-13T10:00:00Z",
            end: "2026-07-13T10:10:00Z",
            tokens: 100,
            cost: 1,
            model: "gpt-5.6-terra"
        )
        let review = journalEntry(
            start: "2026-07-13T10:05:00Z",
            end: "2026-07-13T10:06:00Z",
            tokens: 20,
            cost: 0,
            model: "codex-auto-review"
        )

        let journal = journal(entries: [parent, review], tokens: 120, cost: 1)

        XCTAssertEqual(journal.todayEntries.count, 1)
        XCTAssertEqual(journal.todayEntries[0].tokens, 120)
        XCTAssertEqual(journal.todayEntries[0].cost, 1)
        XCTAssertEqual(journal.todayEntries[0].startedAt, parent.startedAt)
        XCTAssertEqual(journal.todayEntries[0].endedAt, parent.endedAt)
        XCTAssertEqual(journal.last7DayGroups[0].totalDurationSeconds, 600)
    }

    func testTrailingAutoReviewWithinFiveMinutesMergesIntoParentWorkSegment() {
        let parent = journalEntry(
            start: "2026-07-13T10:00:00Z",
            end: "2026-07-13T10:10:00Z",
            tokens: 100,
            cost: 1,
            model: "gpt-5.6-terra"
        )
        let review = journalEntry(
            start: "2026-07-13T10:12:00Z",
            end: "2026-07-13T10:13:00Z",
            tokens: 20,
            cost: 0,
            model: "codex-auto-review"
        )

        let journal = journal(entries: [parent, review], tokens: 120, cost: 1)

        XCTAssertEqual(journal.todayEntries.count, 1)
        XCTAssertEqual(journal.todayEntries[0].endedAt, review.endedAt)
        XCTAssertEqual(journal.todayEntries[0].durationSeconds, 780)
        XCTAssertEqual(journal.todayEntries[0].tokens, 120)
    }

    func testAutoReviewOutsideFiveMinuteWindowRemainsSeparate() {
        let parent = journalEntry(
            start: "2026-07-13T10:00:00Z",
            end: "2026-07-13T10:10:00Z",
            tokens: 100,
            cost: 1,
            model: "gpt-5.6-terra"
        )
        let review = journalEntry(
            start: "2026-07-13T10:16:00Z",
            end: "2026-07-13T10:17:00Z",
            tokens: 20,
            cost: 0,
            model: "codex-auto-review"
        )

        let journal = journal(entries: [parent, review], tokens: 120, cost: 1)

        XCTAssertEqual(journal.todayEntries.count, 2)
        XCTAssertEqual(journal.last7DayGroups[0].totalDurationSeconds, 660)
    }

    private func journal(
        entries: [UsageSnapshot.JournalEntry],
        tokens: Int,
        cost: Decimal
    ) -> UsageDomainModel.JournalSummary {
        let usage = UsageSnapshot(
            dailyTokenUsage: [
                .init(date: "2026-07-13", tokens: tokens, cost: cost)
            ],
            journalEntries: entries
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return UsageDomainService.makeDomainModel(
            usage: usage,
            calendar: calendar,
            now: date("2026-07-13T12:00:00Z")
        ).journal
    }

    private func journalEntry(
        start: String,
        end: String,
        tokens: Int,
        cost: Decimal,
        model: String
    ) -> UsageSnapshot.JournalEntry {
        UsageSnapshot.JournalEntry(
            id: start,
            startedAt: date(start),
            endedAt: date(end),
            tokens: tokens,
            cost: cost,
            sourcePath: "/tmp/session.jsonl",
            model: model
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
