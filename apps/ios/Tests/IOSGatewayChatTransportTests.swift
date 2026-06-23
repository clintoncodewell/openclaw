import Foundation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import Testing
@testable import OpenClaw

@Suite struct IOSGatewayChatTransportTests {
    private func object(from json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        let value = try JSONSerialization.jsonObject(with: data)
        return try #require(value as? [String: Any])
    }

    // The gateway agent.wait surface only ever returns status "ok" | "error" | "timeout"
    // (plus "pending" from the run-wait layer). Tests assert against that real set.

    @Test func agentWaitOutcomeMapsOkToCompleted() {
        #expect(IOSGatewayChatTransport.agentWaitOutcome(status: "ok", error: nil) == .completed)
        #expect(IOSGatewayChatTransport.agentWaitOutcome(status: " OK ", error: nil) == .completed)
    }

    @Test func agentWaitOutcomeMapsErrorToFailed() {
        #expect(IOSGatewayChatTransport.agentWaitOutcome(status: "error", error: "boom") == .failed("boom"))
        // A failed run with no message still surfaces as a failure with a default reason.
        #expect(IOSGatewayChatTransport.agentWaitOutcome(status: "error", error: nil) == .failed("Chat failed"))
        #expect(IOSGatewayChatTransport.agentWaitOutcome(status: "error", error: "  ") == .failed("Chat failed"))
    }

    @Test func agentWaitOutcomeKeepsLiveTimeoutStillRunning() {
        // Live wait-window elapse: status "timeout" with NO endedAt and NO stopReason must re-attach.
        #expect(IOSGatewayChatTransport.agentWaitOutcome(status: "timeout", error: nil) == .stillRunning)
        // pendingError grace frame is non-terminal even if other fields look terminal-ish.
        #expect(
            IOSGatewayChatTransport.agentWaitOutcome(
                status: "timeout",
                error: nil,
                endedAt: 1234,
                stopReason: "rpc",
                pendingError: true) == .stillRunning)
    }

    @Test func agentWaitOutcomeMapsTerminalTimeoutToFailed() {
        // Genuinely terminal aborted/timed-out run: status "timeout" carries endedAt (and stopReason).
        #expect(
            IOSGatewayChatTransport.agentWaitOutcome(
                status: "timeout",
                error: "aborted",
                endedAt: 1234,
                stopReason: "rpc") == .failed("aborted"))
        // endedAt alone (no error, no stopReason) is still terminal -> failed with default reason.
        #expect(
            IOSGatewayChatTransport.agentWaitOutcome(status: "timeout", error: nil, endedAt: 1234) == .failed("Chat failed"))
        // A non-empty stopReason without endedAt is also terminal (defensive: terminal aborts carry both).
        #expect(
            IOSGatewayChatTransport.agentWaitOutcome(status: "timeout", error: nil, stopReason: "stop") == .failed("Chat failed"))
    }

    @Test func agentWaitOutcomeMapsPendingAndUnknownStillRunning() {
        #expect(IOSGatewayChatTransport.agentWaitOutcome(status: "pending", error: nil) == .stillRunning)
        #expect(IOSGatewayChatTransport.agentWaitOutcome(status: "weird", error: nil) == .stillRunning)
        #expect(IOSGatewayChatTransport.agentWaitOutcome(status: nil, error: nil) == .stillRunning)
    }

    @Test func agentWaitTimeoutAddsGatewayMargin() {
        #expect(IOSGatewayChatTransport.agentWaitRequestTimeoutSeconds(timeoutMs: 1) == 6)
        #expect(IOSGatewayChatTransport.agentWaitRequestTimeoutSeconds(timeoutMs: 1000) == 6)
        #expect(IOSGatewayChatTransport.agentWaitRequestTimeoutSeconds(timeoutMs: 30000) == 35)
    }

    @Test func agentWaitOutcomeDecodesTerminalSnapshot() throws {
        let completed = try IOSGatewayChatTransport.decodeAgentWaitOutcome(Data(#"{"status":"ok"}"#.utf8))
        #expect(completed == .completed)

        // Live wait-window elapse: timeout with no endedAt re-attaches.
        let liveTimeout = try IOSGatewayChatTransport.decodeAgentWaitOutcome(
            Data(#"{"status":"timeout","timeoutPhase":"gateway_draining"}"#.utf8))
        #expect(liveTimeout == .stillRunning)

        // Terminal aborted run: timeout with endedAt+stopReason fails the turn.
        let abortedTimeout = try IOSGatewayChatTransport.decodeAgentWaitOutcome(
            Data(#"{"status":"timeout","endedAt":1234,"stopReason":"rpc","error":"aborted"}"#.utf8))
        #expect(abortedTimeout == .failed("aborted"))

        // pendingError grace frame stays non-terminal.
        let pendingTimeout = try IOSGatewayChatTransport.decodeAgentWaitOutcome(
            Data(#"{"status":"timeout","pendingError":true}"#.utf8))
        #expect(pendingTimeout == .stillRunning)

        let failed = try IOSGatewayChatTransport.decodeAgentWaitOutcome(
            Data(#"{"status":"error","error":"nope"}"#.utf8))
        #expect(failed == .failed("nope"))
    }

    @Test func listSessionsParamsIncludeGlobalSessionsButNotUnknown() throws {
        let params = try self.object(from: IOSGatewayChatTransport.makeListSessionsParamsJSON(limit: 12))
        #expect(params["includeGlobal"] as? Bool == true)
        #expect(params["includeUnknown"] as? Bool == false)
        #expect(params["limit"] as? Int == 12)
    }

    @Test func chatSendParamsOmitEmptyAttachmentsAndKeepSessionFields() throws {
        let params = try self.object(
            from: IOSGatewayChatTransport.makeChatSendParamsJSON(
                sessionKey: "agent:main",
                message: "hello",
                thinking: "low",
                idempotencyKey: "send-1",
                attachments: []))
        #expect(params["sessionKey"] as? String == "agent:main")
        #expect(params["message"] as? String == "hello")
        #expect(params["thinking"] as? String == "low")
        #expect(params["idempotencyKey"] as? String == "send-1")
        #expect(params["timeoutMs"] as? Int == IOSGatewayChatTransport.defaultChatSendTimeoutMs)
        #expect(params["attachments"] == nil)
    }

    @Test func requestsFailFastWhenGatewayNotConnected() async {
        let gateway = GatewayNodeSession()
        let transport = IOSGatewayChatTransport(gateway: gateway)

        do {
            _ = try await transport.requestHistory(sessionKey: "node-test")
            Issue.record("Expected requestHistory to throw when gateway not connected")
        } catch {}

        do {
            _ = try await transport.sendMessage(
                sessionKey: "node-test",
                message: "hello",
                thinking: "low",
                idempotencyKey: "idempotency",
                attachments: [])
            Issue.record("Expected sendMessage to throw when gateway not connected")
        } catch {}

        do {
            _ = try await transport.requestHealth(timeoutMs: 250)
            Issue.record("Expected requestHealth to throw when gateway not connected")
        } catch {}

        do {
            try await transport.resetSession(sessionKey: "node-test")
            Issue.record("Expected resetSession to throw when gateway not connected")
        } catch {}

        do {
            try await transport.setActiveSessionKey("node-test")
            Issue.record("Expected setActiveSessionKey to throw when gateway not connected")
        } catch {}
    }

    @Test func mapsSessionMessageEventToSessionMessage() {
        let payload = AnyCodable([
            "sessionKey": AnyCodable("agent:main:main"),
            "agentId": AnyCodable("main"),
            "messageId": AnyCodable("msg-1"),
            "messageSeq": AnyCodable(7),
            "message": AnyCodable([
                "role": AnyCodable("assistant"),
                "content": AnyCodable([
                    AnyCodable([
                        "type": AnyCodable("text"),
                        "text": AnyCodable("agent reply"),
                    ]),
                ]),
                "timestamp": AnyCodable(1234.5),
            ]),
        ])
        let frame = EventFrame(
            type: "event",
            event: "session.message",
            payload: payload,
            seq: 1,
            stateversion: nil)
        let mapped = IOSGatewayChatTransport.mapEventFrame(frame)

        switch mapped {
        case let .sessionMessage(message):
            #expect(message.sessionKey == "agent:main:main")
            #expect(message.agentId == "main")
            #expect(message.messageId == "msg-1")
            #expect(message.messageSeq == 7)
            #expect(message.message?.role == "assistant")
            #expect(message.message?.content.first?.text == "agent reply")
        default:
            Issue.record("expected .sessionMessage from session.message event, got \(String(describing: mapped))")
        }
    }

    @Test func mapsChatEventToChat() {
        let payload = AnyCodable([
            "runId": AnyCodable("run-1"),
            "sessionKey": AnyCodable("main"),
            "state": AnyCodable("final"),
        ])
        let frame = EventFrame(type: "event", event: "chat", payload: payload, seq: 1, stateversion: nil)
        let mapped = IOSGatewayChatTransport.mapEventFrame(frame)

        switch mapped {
        case let .chat(chat):
            #expect(chat.runId == "run-1")
            #expect(chat.sessionKey == "main")
            #expect(chat.state == "final")
        default:
            Issue.record("expected .chat from chat event, got \(String(describing: mapped))")
        }
    }

    @Test func mapsUnknownEventToNil() {
        let frame = EventFrame(
            type: "event",
            event: "unknown",
            payload: AnyCodable(["a": AnyCodable(1)]),
            seq: 1,
            stateversion: nil)
        let mapped = IOSGatewayChatTransport.mapEventFrame(frame)
        #expect(mapped == nil)
    }
}
