import Foundation
import Testing
@testable import OpenClawChatUI

@Suite struct ChatHistoryInFlightRunDecodeTests {
    @Test func decodesInFlightRunFromHistoryPayload() throws {
        let json = Data(#"""
        {
          "sessionKey": "agent:main:main",
          "sessionId": "sess-1",
          "messages": [],
          "thinkingLevel": "off",
          "inFlightRun": { "runId": "run-42", "text": "partial" }
        }
        """#.utf8)
        let payload = try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: json)
        #expect(payload.inFlightRun?.runId == "run-42")
        #expect(payload.inFlightRun?.text == "partial")
    }

    @Test func decodesInFlightRunWithoutText() throws {
        // The run id is the recovery contract; buffered text is optional (e.g. Codex runs).
        let json = Data(#"""
        { "sessionKey": "main", "messages": [], "inFlightRun": { "runId": "run-7" } }
        """#.utf8)
        let payload = try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: json)
        #expect(payload.inFlightRun?.runId == "run-7")
        #expect(payload.inFlightRun?.text == nil)
    }

    @Test func absentInFlightRunDecodesToNil() throws {
        let json = Data(#"{ "sessionKey": "main", "messages": [] }"#.utf8)
        let payload = try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: json)
        #expect(payload.inFlightRun == nil)
    }
}
