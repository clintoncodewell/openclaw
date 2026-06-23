import Foundation
import OpenClawChatUI
import OpenClawKit
import OpenClawProtocol
import OSLog

struct IOSGatewayChatTransport: OpenClawChatTransport {
    static let logger = Logger(subsystem: "ai.openclawfoundation.app", category: "ios.chat.transport")
    static let defaultChatSendTimeoutMs = 30000
    private let gateway: GatewayNodeSession

    private struct CreateSessionParams: Codable {
        var key: String
        var label: String?
        var parentSessionKey: String?
    }

    private struct RunParams: Codable {
        var sessionKey: String
        var runId: String
    }

    private struct ListSessionsParams: Codable {
        var includeGlobal: Bool
        var includeUnknown: Bool
        var limit: Int?
    }

    private struct SessionKeyParams: Codable {
        var key: String
    }

    private struct ChatSendParams: Codable {
        var sessionKey: String
        var message: String
        var thinking: String
        var attachments: [OpenClawChatAttachmentPayload]?
        var timeoutMs: Int
        var idempotencyKey: String
    }

    private struct AgentWaitParams: Codable {
        var runId: String
        var timeoutMs: Int
    }

    // The gateway's agent.wait response status is the closed set "ok" | "error" | "timeout"
    // (plus "pending" from the run-wait layer). "timeout" is OVERLOADED: it is returned both for
    // a live wait-window elapse (run still in flight, non-terminal) AND for a genuinely terminal
    // aborted/timed-out run. The reliable discriminator is `endedAt`: the gateway always sets it on
    // terminal snapshots (agent-wait-dedupe.ts endedAt = endedAt ?? entry.ts; chat.ts abort writes
    // status:"timeout" with endedAt+stopReason) and always omits it on the live wait-window-elapse
    // and pendingError grace frames (agent.ts respond sites; agent-job createPendingErrorTimeoutSnapshot).
    // `pendingError` is an explicit non-terminal flag. livenessState/timeoutPhase/providerStarted are
    // not used for the user-facing outcome today, so they are intentionally not decoded here.
    private struct AgentWaitResponse: Codable {
        var runId: String?
        var status: String?
        var error: String?
        var stopReason: String?
        var endedAt: Double?
        var pendingError: Bool?
    }

    /// Map an agent.wait response to the closed outcome the view model consumes.
    /// The gateway only ever returns status "ok" | "error" | "timeout" | "pending".
    /// - "ok" -> `.completed`.
    /// - "error" -> `.failed`.
    /// - "timeout" is terminal (aborted/timed_out) ONLY when it carries `endedAt` (or a non-empty
    ///   `stopReason`); a live wait-window elapse has neither, so it stays `.stillRunning` and
    ///   re-attaches the SAME run. `pendingError` forces `.stillRunning` (retry grace, non-terminal).
    /// - "pending" and any unknown status -> `.stillRunning`: a re-wait either resolves to a real
    ///   terminal status or keeps the turn working.
    static func agentWaitOutcome(
        status rawStatus: String?,
        error: String?,
        endedAt: Double? = nil,
        stopReason: String? = nil,
        pendingError: Bool? = nil) -> OpenClawAgentWaitOutcome
    {
        let normalizedStatus = (rawStatus ?? "unknown")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let trimmedError = error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let failureReason = trimmedError.isEmpty ? "Chat failed" : trimmedError
        switch normalizedStatus {
        case "ok":
            return .completed
        case "error":
            return .failed(failureReason)
        case "timeout":
            let hasStopReason = (stopReason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            let isTerminal = (endedAt != nil || hasStopReason) && pendingError != true
            return isTerminal ? .failed(failureReason) : .stillRunning
        case "pending":
            return .stillRunning
        default:
            return .stillRunning
        }
    }

    init(gateway: GatewayNodeSession) {
        self.gateway = gateway
    }

    static func agentWaitRequestTimeoutSeconds(timeoutMs: Int) -> Int {
        max(1, Int(ceil(Double(timeoutMs) / 1000.0)) + 5)
    }

    static func makeListSessionsParamsJSON(limit: Int?) throws -> String {
        try self.encodeParams(ListSessionsParams(includeGlobal: true, includeUnknown: false, limit: limit))
    }

    static func makeChatSendParamsJSON(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) throws -> String
    {
        let params = ChatSendParams(
            sessionKey: sessionKey,
            message: message,
            thinking: thinking,
            attachments: attachments.isEmpty ? nil : attachments,
            timeoutMs: self.defaultChatSendTimeoutMs,
            idempotencyKey: idempotencyKey)
        return try self.encodeParams(params)
    }

    // Pure decode for testability: a successful agent.wait RPC frame -> closed outcome.
    static func decodeAgentWaitOutcome(_ data: Data) throws -> OpenClawAgentWaitOutcome {
        let decoded = try JSONDecoder().decode(AgentWaitResponse.self, from: data)
        return self.agentWaitOutcome(
            status: decoded.status,
            error: decoded.error,
            endedAt: decoded.endedAt,
            stopReason: decoded.stopReason,
            pendingError: decoded.pendingError)
    }

    private static func makeCreateSessionParamsJSON(
        key: String,
        label: String?,
        parentSessionKey: String?) throws -> String
    {
        let params = CreateSessionParams(
            key: key,
            label: label,
            parentSessionKey: parentSessionKey)
        return try self.encodeParams(params)
    }

    private static func makeRunParamsJSON(sessionKey: String, runId: String) throws -> String {
        try self.encodeParams(RunParams(sessionKey: sessionKey, runId: runId))
    }

    private static func makeSessionKeyParamsJSON(_ sessionKey: String) throws -> String {
        try self.encodeParams(SessionKeyParams(key: sessionKey))
    }

    private static func makeHistoryParamsJSON(sessionKey: String) throws -> String {
        struct Params: Codable { var sessionKey: String }
        return try self.encodeParams(Params(sessionKey: sessionKey))
    }

    private static func makeAgentWaitParamsJSON(runId: String, timeoutMs: Int) throws -> String {
        try self.encodeParams(AgentWaitParams(runId: runId, timeoutMs: timeoutMs))
    }

    private static func encodeParams(_ params: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(params)
        guard let json = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                params,
                EncodingError.Context(codingPath: [], debugDescription: "Encoded gateway params were not UTF-8"))
        }
        return json
    }

    func createSession(
        key: String,
        label: String?,
        parentSessionKey: String?) async throws -> OpenClawChatCreateSessionResponse
    {
        let json = try Self.makeCreateSessionParamsJSON(
            key: key,
            label: label,
            parentSessionKey: parentSessionKey)
        let res = try await self.gateway.request(method: "sessions.create", paramsJSON: json, timeoutSeconds: 15)
        return try JSONDecoder().decode(OpenClawChatCreateSessionResponse.self, from: res)
    }

    func abortRun(sessionKey: String, runId: String) async throws {
        let json = try Self.makeRunParamsJSON(sessionKey: sessionKey, runId: runId)
        _ = try await self.gateway.request(method: "chat.abort", paramsJSON: json, timeoutSeconds: 10)
    }

    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse {
        let json = try Self.makeListSessionsParamsJSON(limit: limit)
        let res = try await self.gateway.request(method: "sessions.list", paramsJSON: json, timeoutSeconds: 15)
        return try JSONDecoder().decode(OpenClawChatSessionsListResponse.self, from: res)
    }

    func setActiveSessionKey(_ sessionKey: String) async throws {
        struct Params: Codable { var key: String }
        let data = try JSONEncoder().encode(Params(key: sessionKey))
        let json = String(data: data, encoding: .utf8)
        _ = try await self.gateway.request(
            method: "sessions.messages.subscribe",
            paramsJSON: json,
            timeoutSeconds: 10)
    }

    func resetSession(sessionKey: String) async throws {
        let json = try Self.makeSessionKeyParamsJSON(sessionKey)
        _ = try await self.gateway.request(method: "sessions.reset", paramsJSON: json, timeoutSeconds: 10)
    }

    func compactSession(sessionKey: String) async throws {
        let json = try Self.makeSessionKeyParamsJSON(sessionKey)
        _ = try await self.gateway.request(method: "sessions.compact", paramsJSON: json, timeoutSeconds: 10)
    }

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload {
        let json = try Self.makeHistoryParamsJSON(sessionKey: sessionKey)
        let res = try await self.gateway.request(method: "chat.history", paramsJSON: json, timeoutSeconds: 15)
        return try JSONDecoder().decode(OpenClawChatHistoryPayload.self, from: res)
    }

    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse
    {
        let startLogMessage =
            "chat.send start sessionKey=\(sessionKey) "
                + "len=\(message.count) attachments=\(attachments.count)"
        Self.logger.info(
            "\(startLogMessage, privacy: .public)")
        GatewayDiagnostics.log(startLogMessage)
        let json = try Self.makeChatSendParamsJSON(
            sessionKey: sessionKey,
            message: message,
            thinking: thinking,
            idempotencyKey: idempotencyKey,
            attachments: attachments)
        do {
            let res = try await self.gateway.request(method: "chat.send", paramsJSON: json, timeoutSeconds: 35)
            let decoded = try JSONDecoder().decode(OpenClawChatSendResponse.self, from: res)
            Self.logger.info("chat.send ok runId=\(decoded.runId, privacy: .public)")
            GatewayDiagnostics.log("chat.send ok runId=\(decoded.runId) status=\(decoded.status)")
            return decoded
        } catch {
            Self.logger.error("chat.send failed \(error.localizedDescription, privacy: .public)")
            GatewayDiagnostics.log("chat.send failed error=\(error.localizedDescription)")
            throw error
        }
    }

    func waitForRunOutcome(runId rawRunId: String, timeoutMs: Int) async -> OpenClawAgentWaitOutcome {
        let runId = rawRunId.trimmingCharacters(in: .whitespacesAndNewlines)
        // No runId means nothing to re-attach to; surface a wait error so the caller backs off
        // and reconciles via chat.history rather than treating it as a finished run.
        guard !runId.isEmpty else { return .waitError }

        do {
            let json = try Self.makeAgentWaitParamsJSON(runId: runId, timeoutMs: timeoutMs)
            let requestTimeoutSeconds = Self.agentWaitRequestTimeoutSeconds(timeoutMs: timeoutMs)
            GatewayDiagnostics.log("agent.wait start runId=\(runId)")
            let res = try await self.gateway.request(
                method: "agent.wait",
                paramsJSON: json,
                timeoutSeconds: requestTimeoutSeconds)
            let outcome = try Self.decodeAgentWaitOutcome(res)
            GatewayDiagnostics.log("agent.wait outcome runId=\(runId) outcome=\(outcome)")
            if outcome != .completed {
                Self.logger.warning(
                    "agent.wait outcome \(String(describing: outcome), privacy: .public) runId=\(runId, privacy: .public)")
            }
            return outcome
        } catch {
            // A thrown RPC error is a transport hiccup (socket timeout / disconnect), NOT a run
            // failure: the run may still be in flight, so report .waitError and let the loop retry.
            Self.logger.warning("agent.wait failed \(error.localizedDescription, privacy: .public)")
            GatewayDiagnostics.log("agent.wait failed runId=\(runId) error=\(error.localizedDescription)")
            return .waitError
        }
    }

    func requestHealth(timeoutMs: Int) async throws -> Bool {
        let seconds = max(1, Int(ceil(Double(timeoutMs) / 1000.0)))
        let res = try await self.gateway.request(method: "health", paramsJSON: nil, timeoutSeconds: seconds)
        return (try? JSONDecoder().decode(OpenClawGatewayHealthOK.self, from: res))?.ok ?? true
    }

    func events() -> AsyncStream<OpenClawChatTransportEvent> {
        AsyncStream { continuation in
            let task = Task {
                let stream = await self.gateway.subscribeServerEvents()
                for await evt in stream {
                    if Task.isCancelled { return }
                    if let mapped = Self.mapEventFrame(evt) {
                        continuation.yield(mapped)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    static func mapEventFrame(_ evt: EventFrame) -> OpenClawChatTransportEvent? {
        switch evt.event {
        case "tick":
            return .tick
        case "seqGap":
            return .seqGap
        case "health":
            guard let payload = evt.payload else { return nil }
            let ok = (try? GatewayPayloadDecoding.decode(
                payload,
                as: OpenClawGatewayHealthOK.self))?.ok ?? true
            return .health(ok: ok)
        case "chat":
            guard let payload = evt.payload else { return nil }
            guard let chatPayload = try? GatewayPayloadDecoding.decode(
                payload,
                as: OpenClawChatEventPayload.self)
            else {
                return nil
            }
            return .chat(chatPayload)
        case "session.message":
            guard let payload = evt.payload else { return nil }
            guard let message = try? GatewayPayloadDecoding.decode(
                payload,
                as: OpenClawSessionMessageEventPayload.self)
            else {
                return nil
            }
            return .sessionMessage(message)
        case "agent":
            guard let payload = evt.payload else { return nil }
            guard let agentPayload = try? GatewayPayloadDecoding.decode(
                payload,
                as: OpenClawAgentEventPayload.self)
            else {
                return nil
            }
            return .agent(agentPayload)
        default:
            return nil
        }
    }
}
