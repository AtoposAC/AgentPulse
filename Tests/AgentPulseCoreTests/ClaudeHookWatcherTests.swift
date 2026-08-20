import Foundation
import XCTest
@testable import AgentPulseCore

final class ClaudeHookWatcherTests: XCTestCase {
    func testParserMapsSupportedEventsToExpectedSignals() throws {
        let expectations: [(String, AgentSignal)] = [
            ("UserPromptSubmit", .thinking),
            ("PreToolUse", .working),
            ("PostToolUse", .thinking),
            ("PostToolUseFailure", .thinking),
            ("PermissionRequest", .attention),
            ("Notification", .attention),
            ("SubagentStart", .working),
            ("SubagentStop", .thinking),
            ("Stop", .done),
            ("StopFailure", .attention),
            ("SessionEnd", .idle)
        ]

        for (eventType, expectedSignal) in expectations {
            let event = try XCTUnwrap(ClaudeHookEventParser.parse(line(eventType: eventType)))
            XCTAssertEqual(event.signal, expectedSignal, eventType)
        }
    }

    func testParserRecognizesTestEventsAndToolNames() throws {
        let event = try XCTUnwrap(ClaudeHookEventParser.parse(line(
            eventType: "PreToolUse",
            extra: ["source": "AgentPulse Test Event", "tool_name": "Read"]
        )))

        XCTAssertTrue(event.isTest)
        XCTAssertEqual(event.toolName, "Read")
        XCTAssertEqual(event.signal, .working)
    }

    @MainActor
    func testClaudeAttentionEventuallyExpiresWithoutFollowUpEvents() {
        let now = date("2026-08-20T12:00:00Z")
        let notification = AgentSnapshot(
            kind: .claude,
            signal: .attention,
            statusReason: "Claude Hook · Notification",
            updatedAt: now.addingTimeInterval(-11 * 60)
        )
        let permission = AgentSnapshot(
            kind: .claude,
            signal: .attention,
            statusReason: "Claude Hook · PermissionRequest",
            updatedAt: now.addingTimeInterval(-30 * 60)
        )

        XCTAssertTrue(AgentPulseStore.shouldExpireClaudeState(notification, at: now))
        XCTAssertFalse(AgentPulseStore.shouldExpireClaudeState(permission, at: now))
        XCTAssertTrue(AgentPulseStore.shouldExpireClaudeState(
            AgentSnapshot(
                kind: .claude,
                signal: .attention,
                statusReason: "Claude Hook · PermissionRequest",
                updatedAt: now.addingTimeInterval(-121 * 60)
            ),
            at: now
        ))
    }

    private func line(eventType: String, extra: [String: String] = [:]) -> String {
        var object = extra
        object["hook_event_name"] = eventType
        object["timestamp"] = "2026-08-20T12:00:00Z"
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}
