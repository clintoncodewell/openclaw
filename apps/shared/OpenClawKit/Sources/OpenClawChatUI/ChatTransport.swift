import Foundation

public enum OpenClawChatTransportEvent: Sendable {
    case health(ok: Bool)
    case tick
    case chat(OpenClawChatEventPayload)
    case sessionMessage(OpenClawSessionMessageEventPayload)
    case agent(OpenClawAgentEventPayload)
    case seqGap
}

/// Closed outcome of a single `agent.wait` round-trip. The gateway returns a *success* RPC
/// frame whose `status` distinguishes a finished run from one whose wait window merely elapsed
/// while it is still in flight, so callers must not collapse this to a Bool: a wait-window
/// expiry is `.stillRunning` (re-attach), only a terminal error/abort is `.failed`, and a
/// dropped/timed-out RPC socket is `.waitError` (transient transport hiccup, retry with backoff).
public enum OpenClawAgentWaitOutcome: Sendable, Equatable {
    /// Run reached a successful terminal snapshot (gateway status "ok").
    case completed
    /// Wait window merely elapsed while the run is still in flight (gateway status "timeout" with
    /// no endedAt, "pending", or pendingError). Re-issuing `agent.wait` with the same runId resumes
    /// waiting on the same run.
    case stillRunning
    /// Run reached a terminal error/abort (gateway status "error", or "timeout" carrying endedAt/
    /// stopReason for an aborted or timed-out run). The associated message is the user-facing reason.
    case failed(String)
    /// The `agent.wait` RPC itself failed (socket timeout / disconnect). Not a run failure.
    case waitError
}

public protocol OpenClawChatTransport: Sendable {
    func createSession(
        key: String,
        label: String?,
        parentSessionKey: String?) async throws -> OpenClawChatCreateSessionResponse

    func requestHistory(sessionKey: String) async throws -> OpenClawChatHistoryPayload
    func listModels() async throws -> [OpenClawChatModelChoice]
    func sendMessage(
        sessionKey: String,
        message: String,
        thinking: String,
        idempotencyKey: String,
        attachments: [OpenClawChatAttachmentPayload]) async throws -> OpenClawChatSendResponse

    func abortRun(sessionKey: String, runId: String) async throws
    func listSessions(limit: Int?) async throws -> OpenClawChatSessionsListResponse
    func setSessionModel(sessionKey: String, model: String?) async throws
    func setSessionThinking(sessionKey: String, thinkingLevel: String) async throws

    func requestHealth(timeoutMs: Int) async throws -> Bool
    func waitForRunOutcome(runId: String, timeoutMs: Int) async -> OpenClawAgentWaitOutcome
    func events() -> AsyncStream<OpenClawChatTransportEvent>

    func setActiveSessionKey(_ sessionKey: String) async throws
    func resetSession(sessionKey: String) async throws
    func compactSession(sessionKey: String) async throws
}

extension OpenClawChatTransport {
    public func createSession(
        key _: String,
        label _: String?,
        parentSessionKey _: String?) async throws -> OpenClawChatCreateSessionResponse
    {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.create not supported by this transport"])
    }

    public func setActiveSessionKey(_: String) async throws {}

    public func waitForRunOutcome(runId _: String, timeoutMs _: Int) async -> OpenClawAgentWaitOutcome {
        // Transports without an agent.wait surface cannot report progress; treat as a transient
        // wait failure so the re-attach loop falls back to history polling rather than failing the run.
        .waitError
    }

    public func resetSession(sessionKey _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.reset not supported by this transport"])
    }

    public func compactSession(sessionKey _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.compact not supported by this transport"])
    }

    public func abortRun(sessionKey _: String, runId _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "chat.abort not supported by this transport"])
    }

    public func listSessions(limit _: Int?) async throws -> OpenClawChatSessionsListResponse {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.list not supported by this transport"])
    }

    public func listModels() async throws -> [OpenClawChatModelChoice] {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "models.list not supported by this transport"])
    }

    public func setSessionModel(sessionKey _: String, model _: String?) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.patch(model) not supported by this transport"])
    }

    public func setSessionThinking(sessionKey _: String, thinkingLevel _: String) async throws {
        throw NSError(
            domain: "OpenClawChatTransport",
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "sessions.patch(thinkingLevel) not supported by this transport"])
    }
}
