//
//  FoundationModelsService.swift
//  afm-server
//
//  Created by Michael Doise on 9/14/25.
//

import Foundation
import OSLog
#if canImport(FoundationModels)
import FoundationModels
#endif
// We use system model APIs for on-device language model access

// MARK: - OpenAI-Compatible Types

nonisolated struct ChatCompletionRequest: Codable, Sendable {
    struct Message: Codable {
        let role: String
        let content: String
        let name: String?
        let tool_calls: [OAIToolCall]?
        let tool_call_id: String?

        // Support both classic string content and OpenAI-style structured content arrays.
        // We'll flatten any array of content parts into a single text string by concatenating text segments.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.role = (try? c.decode(String.self, forKey: .role)) ?? "user"
            self.name = try? c.decode(String.self, forKey: .name)
            self.tool_calls = try? c.decode([OAIToolCall].self, forKey: .tool_calls)
            self.tool_call_id = try? c.decode(String.self, forKey: .tool_call_id)
            // Try as plain string first
            if let s = try? c.decode(String.self, forKey: .content) {
                self.content = s
                return
            }
            // Tool-call assistant messages often send null content.
            if (try? c.decodeNil(forKey: .content)) == true {
                self.content = ""
                return
            }
            // Try as array of strings
            if let arr = try? c.decode([String].self, forKey: .content) {
                self.content = arr.joined(separator: "\n")
                return
            }
            // Try as array of structured parts
            if let parts = try? c.decode([OAContentPart].self, forKey: .content) {
                let text = parts.compactMap { $0.text }.joined(separator: "")
                self.content = text
                return
            }
            // Try as a single structured part object
            if let part = try? c.decode(OAContentPart.self, forKey: .content) {
                self.content = part.text ?? ""
                return
            }
            // Fallback empty
            self.content = ""
        }

        init(role: String, content: String, name: String? = nil, toolCalls: [OAIToolCall]? = nil, toolCallID: String? = nil) {
            self.role = role
            self.content = content
            self.name = name
            self.tool_calls = toolCalls
            self.tool_call_id = toolCallID
        }

        enum CodingKeys: String, CodingKey { case role, content, name, tool_calls, tool_call_id }
    }
    let model: String
    let messages: [Message]
    let temperature: Double?
    let max_tokens: Int?
    let stream: Bool?
    let multi_segment: Bool?
    // OpenAI-style tools support (optional)
    let tools: [OAITool]?
    let tool_choice: ToolChoice?
    var session_id: String?
}

// Content part per OpenAI structured content. We only use text; non-text parts are ignored.
nonisolated private struct OAContentPart: Codable, Sendable {
    let type: String?
    let text: String?
}

nonisolated struct ChatCompletionResponse: Codable, Sendable {
    struct Choice: Codable {
        struct Message: Codable {
            let role: String
            let content: String
            let tool_calls: [OAIToolCall]?

            init(role: String, content: String, toolCalls: [OAIToolCall]? = nil) {
                self.role = role
                self.content = content
                self.tool_calls = toolCalls
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(role, forKey: .role)
                if content.isEmpty && !(tool_calls?.isEmpty ?? true) {
                    try container.encodeNil(forKey: .content)
                } else {
                    try container.encode(content, forKey: .content)
                }
                try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
            }

            enum CodingKeys: String, CodingKey {
                case role
                case content
                case tool_calls
            }
        }
        let index: Int
        let message: Message
        let finish_reason: String?
    }
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [Choice]
    var session_id: String?
}

// MARK: - OpenAI Tools Types

nonisolated struct OAITool: Codable, Sendable {
    let type: String // expecting "function"
    let function: OAIFunction?
}

nonisolated struct OAIFunction: Codable, Sendable {
    let name: String
    let description: String?
    let parameters: JSONValue? // arbitrary JSON schema, not used by executor
}

nonisolated struct OAIToolCall: Codable, Sendable {
    let id: String
    let type: String
    let function: OAIFunctionCall

    init(id: String, type: String = "function", function: OAIFunctionCall) {
        self.id = id
        self.type = type
        self.function = function
    }
}

nonisolated struct OAIFunctionCall: Codable, Sendable {
    let name: String
    let arguments: String
}

nonisolated enum ToolChoice: Codable, Sendable {
    case none
    case auto
    case required
    case function(name: String)

    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            switch s {
            case "none": self = .none
            case "auto": self = .auto
            case "required": self = .required
            default: self = .auto
            }
            return
        }
        struct FuncWrap: Codable { let type: String?; let function: Func? }
        struct Func: Codable { let name: String }
        if let f = try? decoder.singleValueContainer().decode(FuncWrap.self), let name = f.function?.name {
            self = .function(name: name)
            return
        }
        self = .auto
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .none: var c = encoder.singleValueContainer(); try c.encode("none")
        case .auto: var c = encoder.singleValueContainer(); try c.encode("auto")
        case .required: var c = encoder.singleValueContainer(); try c.encode("required")
        case .function(let name):
            struct Wrapper: Codable { let type: String; let function: Inner }
            struct Inner: Codable { let name: String }
            var c = encoder.singleValueContainer()
            try c.encode(Wrapper(type: "function", function: Inner(name: name)))
        }
    }
}

// A minimal JSON value tree for decoding arbitrary tool parameter shapes
nonisolated enum JSONValue: Codable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let d = try? c.decode(Double.self) { self = .number(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let o = try? decoder.container(keyedBy: DynamicCodingKeys.self) {
            var dict: [String: JSONValue] = [:]
            for key in o.allKeys {
                let v = try o.decode(JSONValue.self, forKey: key)
                dict[key.stringValue] = v
            }
            self = .object(dict)
            return
        }
        if var a = try? decoder.unkeyedContainer() {
            var arr: [JSONValue] = []
            while !a.isAtEnd { arr.append(try a.decode(JSONValue.self)) }
            self = .array(arr)
            return
        }
        self = .null
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let s): var c = encoder.singleValueContainer(); try c.encode(s)
        case .number(let d): var c = encoder.singleValueContainer(); try c.encode(d)
        case .bool(let b): var c = encoder.singleValueContainer(); try c.encode(b)
        case .null: var c = encoder.singleValueContainer(); try c.encodeNil()
        case .object(let dict):
            var o = encoder.container(keyedBy: DynamicCodingKeys.self)
            for (k,v) in dict { try o.encode(v, forKey: DynamicCodingKeys(stringValue: k)!) }
        case .array(let arr):
            var a = encoder.unkeyedContainer()
            for v in arr { try a.encode(v) }
        }
    }
}

nonisolated struct DynamicCodingKeys: CodingKey, Sendable {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
nonisolated struct ClientToolDecision {
    @Guide(description: "Choose tool_call when the next assistant turn should call one of the provided client tools. Choose answer when no tool is needed or tool results already answer the request.", .anyOf(["answer", "tool_call"]))
    let action: String

    @Guide(description: "Exact name of the client tool to call. Must be empty when action is answer.")
    let toolName: String

    @Guide(description: "Arguments for the selected tool as one valid JSON object string. Must be {} when action is answer.")
    let argumentsJSON: String

    @Guide(description: "Direct assistant response when action is answer. Must be empty when action is tool_call.")
    let answer: String
}
#endif

// MARK: - OpenAI-Compatible Text Completions

nonisolated struct TextCompletionRequest: Codable, Sendable {
    let model: String
    let prompt: String
    let temperature: Double?
    let max_tokens: Int?
    let stream: Bool?

    // Support legacy clients that send prompt as either a string or an array of strings
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try c.decode(String.self, forKey: .model)
        self.temperature = try? c.decode(Double.self, forKey: .temperature)
        self.max_tokens = try? c.decode(Int.self, forKey: .max_tokens)
        self.stream = try? c.decode(Bool.self, forKey: .stream)
        if let s = try? c.decode(String.self, forKey: .prompt) {
            self.prompt = s
        } else if let arr = try? c.decode([String].self, forKey: .prompt) {
            self.prompt = arr.joined(separator: "\n\n")
        } else {
            self.prompt = ""
        }
    }
}

nonisolated struct TextCompletionResponse: Codable, Sendable {
    struct Choice: Codable {
        let text: String
        let index: Int
        let logprobs: String? // null in our case
        let finish_reason: String?
    }
    let id: String
    let object: String // "text_completion"
    let created: Int
    let model: String
    let choices: [Choice]
}

// MARK: - OpenAI-Compatible Models

nonisolated struct OpenAIModel: Codable, Sendable {
    let id: String
    let object: String // "model"
    let created: Int
    let owned_by: String
}

nonisolated struct OpenAIModelList: Codable, Sendable {
    let object: String // "list"
    let data: [OpenAIModel]
}

// MARK: - Inference Semaphore

/// Limits concurrent LLM inference calls to prevent memory pressure and optimize throughput.
/// Requests beyond the limit wait in a FIFO queue until a slot opens.
actor InferenceSemaphore {
    private let maxConcurrent: Int
    private var running: Int = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Total requests completed since server start
    private var totalCompleted: Int = 0
    /// Total requests that had to wait in queue
    private var totalQueued: Int = 0

    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }

    func acquire() async {
        if running < maxConcurrent {
            running += 1
            return
        }
        totalQueued += 1
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    func release() {
        running -= 1
        totalCompleted += 1
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            running += 1
            next.resume()
        }
    }

    var stats: (running: Int, queued: Int, maxConcurrent: Int, totalCompleted: Int, totalQueued: Int) {
        (running, waiting.count, maxConcurrent, totalCompleted, totalQueued)
    }
}

// MARK: - Session Manager

#if canImport(FoundationModels)
/// Caches LanguageModelSession instances by ID so conversations maintain context across turns.
/// Sessions expire after 30 minutes of inactivity and the cache holds at most 50 sessions.
@available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
actor SessionManager {
    private struct CachedSession {
        let session: LanguageModelSession
        var lastAccessed: Date
    }

    private var cache: [String: CachedSession] = [:]
    private let maxSessions = 50
    private let ttl: TimeInterval = 30 * 60

    func get(_ id: String) -> LanguageModelSession? {
        guard var entry = cache[id] else { return nil }
        if Date().timeIntervalSince(entry.lastAccessed) > ttl {
            cache.removeValue(forKey: id)
            return nil
        }
        entry.lastAccessed = Date()
        cache[id] = entry
        return entry.session
    }

    func store(_ id: String, session: LanguageModelSession) {
        evictIfNeeded()
        cache[id] = CachedSession(session: session, lastAccessed: Date())
    }

    private func evictIfNeeded() {
        let now = Date()
        cache = cache.filter { now.timeIntervalSince($0.value.lastAccessed) <= ttl }
        while cache.count >= maxSessions {
            if let oldest = cache.min(by: { $0.value.lastAccessed < $1.value.lastAccessed }) {
                cache.removeValue(forKey: oldest.key)
            }
        }
    }

    var count: Int { cache.count }
}
#endif

// MARK: - Foundation Models Service

/// A service that bridges OpenAI-compatible requests to Apple's on-device Foundation Models.
nonisolated final class FoundationModelsService: @unchecked Sendable {
    static let shared = FoundationModelsService()
    private let logger = Logger(subsystem: "online.techopolis.afm-server", category: "FoundationModelsService")
    private let createdEpoch: Int = Int(Date().timeIntervalSince1970)

    /// Controls how many LLM inference calls run concurrently.
    /// Additional requests queue in FIFO order until a slot opens.
    let inferenceSemaphore = InferenceSemaphore(maxConcurrent: 3)

    /// Backing storage for the session manager (type-erased for conditional compilation)
    private var _sessionManager: Any? = nil

    #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    var sessionManager: SessionManager {
        if let existing = _sessionManager as? SessionManager { return existing }
        let manager = SessionManager()
        _sessionManager = manager
        return manager
    }
    #endif

    private init() {}

    // MARK: Public API

    /// Handles an OpenAI-compatible chat completion request and returns a response.
    /// Requests are queued through the inference semaphore to manage concurrency.
    func handleChatCompletion(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        await inferenceSemaphore.acquire()
        defer { Task { await inferenceSemaphore.release() } }

        let inferenceStart = ContinuousClock.now

        // If a client advertises tools, act as an OpenAI-compatible model
        // backend: return tool_calls for the client harness to execute on its
        // own machine, then answer after it sends role=tool results.
        if let tools = request.tools, !tools.isEmpty {
            let result = try await handleChatCompletionWithTools(request, tools: tools)
            let elapsed = ContinuousClock.now - inferenceStart
            let ttft = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let outputLen = result.choices.first?.message.content.count ?? 0
            await ServerMetrics.shared.recordInference(tokens: max(1, outputLen / 4), timeToFirstToken: ttft)
            return result
        }

        // If the user asks for local machine facts or terminal/file work, use
        // Foundation Models' native Tool mechanism even when the client did not
        // send an OpenAI tools array. The Swift Tool.call(arguments:) method is
        // the execution hook; the model receives observed tool output before it
        // writes the final answer.
        if shouldOfferNativeFileTools(for: request) {
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                do {
                    let output = try await generateWithNativeFileTools(request: request)
                    let result = makeChatResponse(request: request, content: output, finishReason: "stop")
                    let elapsed = ContinuousClock.now - inferenceStart
                    let ttft = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    await ServerMetrics.shared.recordInference(tokens: max(1, output.count / 4), timeToFirstToken: ttft)
                    return result
                } catch {
                    logger.error("[tools] Native local tools failed before text fallback: \(String(describing: error))")
                    let output = localToolUnavailableMessage(error: error)
                    let result = makeChatResponse(request: request, content: output, finishReason: "stop")
                    let elapsed = ContinuousClock.now - inferenceStart
                    let ttft = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    await ServerMetrics.shared.recordInference(tokens: max(1, output.count / 4), timeToFirstToken: ttft)
                    return result
                }
            }
            #endif
        }

        // Build a context-aware prompt that fits within the model's context by summarizing older content when needed.
        let prompt = await prepareChatPrompt(messages: request.messages, model: request.model, temperature: request.temperature, maxTokens: request.max_tokens)
        logger.log("[chat] model=\(request.model, privacy: .public) messages=\(request.messages.count) promptLen=\(prompt.count)")
        AppLog.info("Inference started for \(request.model)", source: "model")

        // Call into Foundation Models.
        let output = try await generateText(model: request.model, prompt: prompt, temperature: request.temperature, maxTokens: request.max_tokens)
        logger.log("[chat] outputLen=\(output.count)")

        let elapsed = ContinuousClock.now - inferenceStart
        let ttft = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        await ServerMetrics.shared.recordInference(tokens: max(1, output.count / 4), timeToFirstToken: ttft)
        AppLog.info("Inference completed for \(request.model) (\(output.count) chars)", source: "model")

        let response = ChatCompletionResponse(
            id: "chatcmpl_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: request.model,
            choices: [
                .init(
                    index: 0,
                    message: .init(role: "assistant", content: output),
                    finish_reason: "stop"
                )
            ]
        )
        return response
    }

    // MARK: - True Token Streaming

    /// Streams a chat completion token-by-token using Foundation Models' streamResponse API.
    /// Each delta (new text since last yield) is passed to the `emit` callback immediately.
    /// Falls back to single-response chunking on systems without FoundationModels.
    /// Returns the resolved session ID (existing or newly created) for the caller to include in SSE.
    @discardableResult
    func streamChatCompletion(
        messages: [ChatCompletionRequest.Message],
        model: String,
        temperature: Double?,
        sessionID: String? = nil,
        emit: @escaping @Sendable (String) async -> Void
    ) async throws -> String {
        await inferenceSemaphore.acquire()
        defer { Task { await inferenceSemaphore.release() } }

        let resolvedID = sessionID ?? UUID().uuidString
        AppLog.info("Streaming inference started for \(model)", source: "model")

        // Metrics: track TTFT and token count via a Sendable tracker
        let tracker = StreamMetricsTracker()

        let wrappedEmit: @Sendable (String) async -> Void = { delta in
            tracker.recordDelta(delta)
            await emit(delta)
        }

        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            try await streamWithFoundationModels(
                messages: messages,
                model: model,
                temperature: temperature,
                sessionID: resolvedID,
                emit: wrappedEmit
            )
            await ServerMetrics.shared.recordInference(tokens: tracker.tokenCount, timeToFirstToken: tracker.ttft)
            return resolvedID
        }
        #endif

        // Fallback for systems without FoundationModels: generate full response and chunk it
        AppLog.warning("Streaming fallback path used for \(model)", source: "model")
        let prompt = await prepareChatPrompt(
            messages: messages, model: model,
            temperature: temperature, maxTokens: nil
        )
        let output = try await generateText(
            model: model, prompt: prompt,
            temperature: temperature, maxTokens: nil
        )
        for chunk in StreamChunker.chunk(text: output, size: 16) {
            await wrappedEmit(chunk)
        }
        await ServerMetrics.shared.recordInference(tokens: tracker.tokenCount, timeToFirstToken: tracker.ttft)
        AppLog.info("Streaming inference completed for \(model)", source: "model")
        return resolvedID
    }

    #if canImport(FoundationModels)
    /// True token-by-token streaming using LanguageModelSession.streamResponse(to:).
    /// Reuses a cached session when sessionID matches, otherwise creates and caches a new one.
    /// The stream yields cumulative content; we compute deltas by comparing with previous content.
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    private func streamWithFoundationModels(
        messages: [ChatCompletionRequest.Message],
        model: String,
        temperature: Double?,
        sessionID: String,
        emit: @escaping @Sendable (String) async -> Void
    ) async throws {
        let systemModel = try systemLanguageModel(for: model)

        switch systemModel.availability {
        case .available:
            break
        case .unavailable(let reason):
            logger.error("[fm-stream] Model unavailable: \(String(describing: reason))")
            AppLog.error("Foundation Models unavailable for streaming: \(String(describing: reason))", source: "model")
            throw NSError(
                domain: "FoundationModelsService", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model unavailable: \(String(describing: reason))"]
            )
        }

        // Extract the system prompt from messages (sent by API clients as the first message).
        // This goes into the session's instructions parameter, NOT into the user prompt.
        // Mixing system instructions into the user message triggers guardrail false positives.
        let clientSystemPrompt = messages.first(where: { $0.role == "system" })?.content
        let instructions = clientSystemPrompt ?? "You are a helpful assistant."

        // Extract ONLY the last user message — this is what we send to the model.
        // Previous conversation context is maintained by the session's built-in transcript.
        let userMessage = messages.last(where: { $0.role == "user" })?.content ?? messages.last?.content ?? ""

        // Try to reuse a cached session
        var session: LanguageModelSession
        let isExistingSession: Bool
        let cacheKey = streamingSessionKey(model: model, sessionID: sessionID)

        if let cached = await sessionManager.get(cacheKey) {
            session = cached
            isExistingSession = true
            logger.log("[fm-stream] reusing cached session \(sessionID, privacy: .public)")
            AppLog.debug("Reusing streaming model session \(sessionID)", source: "model")
        } else {
            // Create session with clean instructions (matching Perspective Chat pattern).
            // DO NOT include model identifiers, temperature text, or other metadata in instructions.
            // Temperature is handled via GenerationOptions, not instruction text.
            session = LanguageModelSession(model: systemModel, instructions: instructions)
            isExistingSession = false
            logger.log("[fm-stream] created new session \(sessionID, privacy: .public) instructions=\(instructions.prefix(80), privacy: .public)")
            AppLog.debug("Created streaming model session \(sessionID)", source: "model")
        }

        // Always send just the user's message — never a concatenated prompt blob.
        // The session maintains conversation history internally for multi-turn context.
        let prompt = await contextBudgetedPrompt(
            userMessage,
            systemModel: systemModel,
            instructions: isExistingSession ? nil : instructions,
            reserveResponseTokens: 1024,
            label: "stream"
        )

        logger.log("[fm-stream] starting stream, prompt len=\(prompt.count), cached=\(isExistingSession)")

        if #available(macOS 26.4, iOS 26.4, visionOS 26.4, *) {
            do {
                let transcriptTokens = try await systemModel.tokenCount(for: session.transcript)
                let promptTokens = try await systemModel.tokenCount(for: prompt)
                let remaining = systemModel.contextSize - transcriptTokens - promptTokens - 1024
                logger.log("[ctx.stream.transcript] contextSize=\(systemModel.contextSize) transcriptTokens=\(transcriptTokens) promptTokens=\(promptTokens) reserve=1024 remaining=\(remaining)")
            } catch {
                logger.warning("[ctx.stream.transcript] tokenCount failed: \(String(describing: error), privacy: .public)")
            }
        }

        do {
            let stream = session.streamResponse(to: prompt)

            var lastContent = ""
            for try await partialResponse in stream {
                let currentContent = partialResponse.content
                if currentContent.count > lastContent.count {
                    let delta = String(currentContent.dropFirst(lastContent.count))
                    if !delta.isEmpty {
                        await emit(delta)
                    }
                }
                lastContent = currentContent
            }

            // Check if the model returned a soft refusal (not thrown as an error).
            // These poison the session transcript and cause every follow-up to refuse too.
            // IMPORTANT: Apple's model often uses Unicode curly apostrophes (\u{2019}) instead of ASCII ('),
            // so we normalize them before matching.
            let lower = lastContent.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            let isSoftRefusal = lower.contains("i can't assist") ||
                lower.contains("i cannot assist") ||
                lower.contains("i'm not able to help") ||
                lower.contains("i can't help with that") ||
                lower.contains("i cannot help with that") ||
                lower.contains("sorry, but i can't") ||
                lower.contains("sorry, i can't") ||
                (lower.contains("sorry") && lower.contains("can't") && lastContent.count < 150)

            if isSoftRefusal {
                // Evict the poisoned session so the next message gets a fresh one
                logger.warning("[fm-stream] Soft refusal detected for session \(sessionID, privacy: .public) — evicting to prevent refusal spiral")
                AppLog.warning("Soft refusal detected; refreshed streaming session", source: "model")
                await sessionManager.store(cacheKey, session: LanguageModelSession(model: systemModel, instructions: instructions))
            } else {
                // Cache the healthy session for reuse
                await sessionManager.store(cacheKey, session: session)
            }

            let cachedCount = await sessionManager.count
            logger.log("[fm-stream] stream complete, total len=\(lastContent.count), refusal=\(isSoftRefusal), session=\(sessionID, privacy: .public), cached sessions=\(cachedCount)")
            AppLog.info("Streaming response completed (\(lastContent.count) chars)", source: "model")
        } catch {
            // Handle ALL errors gracefully to prevent the "Unable to stream" fallback.
            // Always evict the session on error — a poisoned transcript causes refusal spirals.
            let errorDesc = String(reflecting: error).lowercased()
            let isGuardrail = errorDesc.contains("guardrailviolation") || errorDesc.contains("refusal") || errorDesc.contains("safety")

            if isGuardrail {
                logger.warning("[fm-stream] Guardrail/refusal for session \(sessionID, privacy: .public) — evicting session: \(errorDesc.prefix(120), privacy: .public)")
                AppLog.warning("Streaming guardrail/refusal encountered; refreshed session", source: "model")
            } else {
                logger.error("[fm-stream] Stream error for session \(sessionID, privacy: .public) — evicting session: \(errorDesc.prefix(200), privacy: .public)")
                AppLog.error("Streaming error: \(String(describing: error))", source: "model")
            }

            // Always evict — any error during streaming may have corrupted the session transcript
            await sessionManager.store(cacheKey, session: LanguageModelSession(model: systemModel, instructions: instructions))
            await emit("I'm not able to help with that particular request. Could you try rephrasing or asking something different?")
        }
    }
    #endif

    /// Tool-calling orchestration for OpenAI-compatible clients.
    /// Client-provided tools are delegated back as OpenAI `tool_calls` so the
    /// connecting harness can execute them in its own environment.
    private func handleChatCompletionWithTools(_ request: ChatCompletionRequest, tools: [OAITool]) async throws -> ChatCompletionResponse {
        let functionTools = tools.filter { $0.type == "function" && $0.function != nil }
        guard !functionTools.isEmpty else {
            let output = try await generateToolFinalAnswer(request: request, tools: tools)
            return makeChatResponse(request: request, content: output, finishReason: "stop")
        }

        if shouldAnswerAfterClientToolResult(request) {
            let output = try await generateToolFinalAnswer(request: request, tools: tools)
            return makeChatResponse(request: request, content: output, finishReason: "stop")
        }

        if case .none = request.tool_choice ?? .auto {
            let output = try await generateToolFinalAnswer(request: request, tools: tools)
            return makeChatResponse(request: request, content: output, finishReason: "stop")
        }

        // Deterministic fast path: when the request unambiguously maps to a shell/file/terminal
        // command, emit that tool_call directly. The on-device model is unreliable at choosing
        // among many client tools (it has picked `read` for a directory listing, or hallucinated
        // a tool name as a shell command), so prefer the inferred terminal tool_call over the
        // model's pick for these clear cases.
        if let toolCall = inferredClientToolCall(request: request, tools: functionTools, toolChoice: request.tool_choice ?? .auto) {
            logger.log("[tools] deterministic inferred tool_call name=\(toolCall.function.name, privacy: .public) args=\(toolCall.function.arguments, privacy: .public)")
            return makeChatResponse(request: request, content: "", toolCalls: [toolCall], finishReason: "tool_calls")
        }

        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            do {
                let decision = try await generateClientToolDecision(request: request, tools: functionTools)
                if let toolCall = makeClientToolCall(from: decision, request: request, tools: functionTools, toolChoice: request.tool_choice ?? .auto) {
                    if let listing = redirectedDirectoryRead(toolCall, request: request, tools: functionTools) {
                        logger.log("[tools] redirected directory read to listing name=\(listing.function.name, privacy: .public) args=\(listing.function.arguments, privacy: .public)")
                        return makeChatResponse(request: request, content: "", toolCalls: [listing], finishReason: "tool_calls")
                    }
                    logger.log("[tools] delegated client tool_call name=\(toolCall.function.name, privacy: .public)")
                    return makeChatResponse(request: request, content: "", toolCalls: [toolCall], finishReason: "tool_calls")
                }

                if let toolCall = inferredClientToolCall(request: request, tools: functionTools, toolChoice: request.tool_choice ?? .auto) {
                    logger.log("[tools] inferred client tool_call after direct decision name=\(toolCall.function.name, privacy: .public)")
                    return makeChatResponse(request: request, content: "", toolCalls: [toolCall], finishReason: "tool_calls")
                }

                // The decision says "answer" rather than call a tool. Do NOT return
                // decision.answer directly: in multi-turn conversations the on-device model
                // populates that field by echoing the previous assistant message verbatim
                // instead of answering the latest user turn. Use the decision only to choose
                // answer-vs-tool_call, then regenerate the real answer from the conversation.
                let decidedToAnswer = decision.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "tool_call"
                let hasUsableAnswerText = !decision.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if decidedToAnswer || hasUsableAnswerText {
                    let output = try await generateToolFinalAnswer(request: request, tools: tools)
                    return makeChatResponse(request: request, content: output, finishReason: "stop")
                }

                if let toolCall = inferredClientToolCall(request: request, tools: functionTools, toolChoice: request.tool_choice ?? .auto) {
                    logger.log("[tools] inferred client tool_call name=\(toolCall.function.name, privacy: .public)")
                    return makeChatResponse(request: request, content: "", toolCalls: [toolCall], finishReason: "tool_calls")
                }
            } catch {
                logger.error("[tools] client tool decision failed, falling back to final answer: \(String(describing: error))")
                if let toolCall = inferredClientToolCall(request: request, tools: functionTools, toolChoice: request.tool_choice ?? .auto) {
                    logger.log("[tools] inferred client tool_call after decision error name=\(toolCall.function.name, privacy: .public)")
                    return makeChatResponse(request: request, content: "", toolCalls: [toolCall], finishReason: "tool_calls")
                }
            }
        }
        #endif

        let output = try await generateToolFinalAnswer(request: request, tools: tools)
        return makeChatResponse(request: request, content: output, finishReason: "stop")
    }

    // MARK: - Context management for Chat

    /// Prepares a clean user prompt from the messages array.
    /// System prompts are NOT included here — they belong in LanguageModelSession instructions.
    /// Mixing role prefixes (e.g., "system:", "user:") into the prompt text triggers guardrail
    /// false positives because the model interprets it as prompt injection.
    private func prepareChatPrompt(messages: [ChatCompletionRequest.Message], model: String, temperature: Double?, maxTokens: Int?) async -> String {
        // Keep a roomy last-user prompt here; FoundationModels generation paths do
        // exact context accounting with SystemLanguageModel.contextSize/tokenCount.
        let maxInputChars = 32000

        // Find the LAST user message - this is what actually matters
        var lastUserContent = ""
        for msg in messages.reversed() {
            if msg.role == "user" {
                lastUserContent = msg.content
                break
            }
        }

        // Extract just the user's actual request (skip Xcode boilerplate)
        var userRequest = lastUserContent

        // Look for "The user has asked:" pattern from Xcode extension
        if let askedRange = userRequest.range(of: "The user has asked:", options: .caseInsensitive) {
            userRequest = String(userRequest[askedRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Truncate user request if needed
        if userRequest.count > maxInputChars {
            userRequest = String(userRequest.prefix(maxInputChars)) + "..."
        }

        let estimatedTokens = approxTokenCount(userRequest)
        logger.log("[chat.ctx] prepared prompt: chars=\(userRequest.count) tokens≈\(estimatedTokens)")

        // Return ONLY the user's message — no role prefixes, no "assistant:" suffix.
        // The LanguageModelSession handles role separation internally.
        return userRequest
    }

    /// Rough token estimate (heuristic): ~4 chars per token.
    private func approxTokenCount(_ text: String) -> Int {
        return max(1, (text.count + 3) / 4)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func contextBudgetedPrompt(
        _ prompt: String,
        systemModel: SystemLanguageModel,
        instructions: String? = nil,
        tools: [any Tool] = [],
        schema: GenerationSchema? = nil,
        reserveResponseTokens: Int,
        label: String
    ) async -> String {
        let contextSize = systemModel.contextSize
        let reserve = min(max(reserveResponseTokens, 128), max(128, contextSize / 2))
        var candidate = prompt
        var promptTokens = approxTokenCount(candidate)
        var fixedTokens = approxTokenCount(instructions ?? "") + (schema.map { approxTokenCount($0.debugDescription) } ?? 0)
        var usedExactTokenCount = false

        if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *) {
            do {
                var countedFixedTokens = 0
                if let instructions, !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    countedFixedTokens += try await systemModel.tokenCount(for: Instructions(instructions))
                }
                if !tools.isEmpty {
                    countedFixedTokens += try await systemModel.tokenCount(for: tools)
                }
                if let schema {
                    countedFixedTokens += try await systemModel.tokenCount(for: schema)
                }
                fixedTokens = countedFixedTokens
                promptTokens = try await systemModel.tokenCount(for: candidate)
                usedExactTokenCount = true
            } catch {
                logger.warning("[ctx.\(label, privacy: .public)] tokenCount failed; using approximation: \(String(describing: error), privacy: .public)")
            }
        }

        let availablePromptTokens = max(64, contextSize - fixedTokens - reserve)
        if promptTokens > availablePromptTokens {
            var charLimit = max(
                256,
                min(candidate.count, Int(Double(candidate.count) * Double(availablePromptTokens) / Double(max(promptTokens, 1))))
            )

            for _ in 0..<5 {
                candidate = truncatedForPrompt(prompt, limit: charLimit)

                if #available(iOS 26.4, macOS 26.4, visionOS 26.4, *), usedExactTokenCount {
                    do {
                        promptTokens = try await systemModel.tokenCount(for: candidate)
                    } catch {
                        promptTokens = approxTokenCount(candidate)
                        usedExactTokenCount = false
                    }
                } else {
                    promptTokens = approxTokenCount(candidate)
                }

                if promptTokens <= availablePromptTokens || charLimit <= 256 {
                    break
                }
                charLimit = max(256, Int(Double(charLimit) * 0.75))
            }
        }

        let remaining = contextSize - fixedTokens - promptTokens - reserve
        logger.log("[ctx.\(label, privacy: .public)] contextSize=\(contextSize) promptTokens=\(promptTokens) fixedTokens=\(fixedTokens) reserve=\(reserve) remaining=\(remaining) exact=\(usedExactTokenCount)")

        if candidate.count != prompt.count {
            logger.log("[ctx.\(label, privacy: .public)] trimmed prompt chars \(prompt.count) -> \(candidate.count)")
        }

        return candidate
    }
    #endif

    /// Clamp very large input before summarization to avoid exceeding FM limits during the summarization step.
    private func clampForSummarization(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        // Keep head and tail slices to retain both early and late context in the summary input
        let half = maxChars / 2
        let head = text.prefix(half)
        let tail = text.suffix(maxChars - half)
        return String(head) + "\n…\n" + String(tail)
    }

    /// Summarize text using FoundationModels when available; fallback to a naïve extract if not.
    private func summarizeText(_ text: String, targetChars: Int, model: String, temperature: Double?) async -> String {
        let instruction = "Summarize the following content in under \(targetChars) characters, preserving key technical details, APIs, and decisions relevant to the user’s most recent request. Use concise bullet points if helpful."
        let prompt = "Instructions:\n\(instruction)\n\nContent to summarize:\n\n\(text)"
        do {
            let out = try await generateText(model: model, prompt: prompt, temperature: temperature, maxTokens: nil)
            if out.count > targetChars {
                // Light clamp on the generated summary to respect target size
                return String(out.prefix(targetChars))
            }
            return out
        } catch {
            // Fall back to a naïve extract when FM is not available
            let sentences = text.split(separator: ".")
            let head = sentences.prefix(8).joined(separator: ". ")
            let tail = sentences.suffix(4).joined(separator: ". ")
            let combined = "\(head). … \(tail)."
            if combined.count > targetChars {
                return String(combined.prefix(targetChars))
            }
            return combined
        }
    }

    /// Handles an OpenAI-compatible text completion request and returns a response.
    func handleCompletion(_ request: TextCompletionRequest) async throws -> TextCompletionResponse {
        await inferenceSemaphore.acquire()
        defer { Task { await inferenceSemaphore.release() } }
        logger.log("[text] model=\(request.model, privacy: .public) promptLen=\(request.prompt.count)")
        let output = try await generateText(model: request.model, prompt: request.prompt, temperature: request.temperature, maxTokens: request.max_tokens)
        logger.log("[text] outputLen=\(output.count)")

        let response = TextCompletionResponse(
            id: "cmpl_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            object: "text_completion",
            created: Int(Date().timeIntervalSince1970),
            model: request.model,
            choices: [
                .init(text: output, index: 0, logprobs: nil, finish_reason: "stop")
            ]
        )
        return response
    }

    // MARK: - Ollama-compatible chat

    struct OllamaMessage: Codable {
        let role: String
        let content: String
        let tool_calls: [OllamaToolCall]?

        init(role: String, content: String, toolCalls: [OllamaToolCall]? = nil) {
            self.role = role
            self.content = content
            self.tool_calls = toolCalls
        }
    }

    struct OllamaToolCall: Codable {
        let id: String?
        let type: String?
        let function: OllamaFunctionCall
    }

    struct OllamaFunctionCall: Codable {
        let name: String
        let arguments: JSONValue
    }

    struct OllamaChatRequest: Codable {
        let model: String
        let messages: [OllamaMessage]
        let stream: Bool?
        let options: OllamaChatOptions?
        let tools: [OAITool]?
    }

    struct OllamaChatOptions: Codable {
        let temperature: Double?
        let num_predict: Int?
    }

    struct OllamaChatResponse: Codable {
        let model: String
        let created_at: String
        let message: OllamaMessage
        let done: Bool
        let total_duration: Int64?
    }

    func handleOllamaChat(_ request: OllamaChatRequest) async throws -> OllamaChatResponse {
        let temperature = request.options?.temperature
        let maxTokens = request.options?.num_predict
        // Reuse our chat completion pipeline by mapping roles/content
        let mapped = request.messages.map { message in
            ChatCompletionRequest.Message(
                role: message.role,
                content: message.content,
                toolCalls: message.tool_calls?.map { call in
                    OAIToolCall(
                        id: call.id ?? "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                        type: call.type ?? "function",
                        function: OAIFunctionCall(
                            name: call.function.name,
                            arguments: jsonString(call.function.arguments) ?? "{}"
                        )
                    )
                }
            )
        }
        let chatReq = ChatCompletionRequest(
            model: request.model,
            messages: mapped,
            temperature: temperature,
            max_tokens: maxTokens,
            stream: false,
            multi_segment: nil,
            tools: request.tools,
            tool_choice: nil
        )
        let resp = try await handleChatCompletion(chatReq)
        let iso = ISO8601DateFormatter()
        let createdAt = iso.string(from: Date(timeIntervalSince1970: TimeInterval(resp.created)))
        let responseMessage = resp.choices.first?.message
        let ollamaToolCalls = responseMessage?.tool_calls?.map { call in
            OllamaToolCall(
                id: call.id,
                type: call.type,
                function: OllamaFunctionCall(
                    name: call.function.name,
                    arguments: jsonValue(fromJSONString: call.function.arguments) ?? .object([:])
                )
            )
        }
        let outMessage = OllamaMessage(
            role: responseMessage?.role ?? "assistant",
            content: responseMessage?.content ?? "",
            toolCalls: ollamaToolCalls
        )
        return OllamaChatResponse(model: resp.model, created_at: createdAt, message: outMessage, done: true, total_duration: nil)
    }

    /// Returns the list of available models in OpenAI format. For now we expose a single on-device model id.
    func listModels() -> OpenAIModelList {
        let models = availableModels()
        return OpenAIModelList(object: "list", data: models)
    }

    /// Returns a single model by id in OpenAI format, if available.
    func getModel(id: String) -> OpenAIModel? {
        let normalized = (id.removingPercentEncoding ?? id).trimmingCharacters(in: .whitespacesAndNewlines)
        return availableModels().first { model in
            model.id == normalized || "\(model.id):latest" == normalized
        }
    }

    // MARK: Ollama-compatible models list (/api/tags)

    struct OllamaTagDetails: Codable {
        let format: String?
        let family: String?
        let families: [String]?
        let parameter_size: String?
        let quantization_level: String?
    }

    struct OllamaTagModel: Codable {
        let name: String
        let modified_at: String
        let size: Int64?
        let digest: String?
        let details: OllamaTagDetails?
    }

    struct OllamaTagsResponse: Codable {
        let models: [OllamaTagModel]
    }

    func listOllamaTags() -> OllamaTagsResponse {
        let iso = ISO8601DateFormatter()
        let baseModified = iso.string(from: Date(timeIntervalSince1970: TimeInterval(createdEpoch)))
        let baseModel = OllamaTagModel(
            name: "apple.local:latest",
            modified_at: baseModified,
            size: nil,
            digest: nil,
            details: OllamaTagDetails(
                format: "system",
                family: "apple-intelligence",
                families: ["apple-intelligence"],
                parameter_size: nil,
                quantization_level: nil
            )
        )
        let adapters = FoundationModelAdapterRegistry.loadRecords().map { adapter in
            OllamaTagModel(
                name: adapter.ollamaModelName,
                modified_at: iso.string(from: adapter.addedAt),
                size: nil,
                digest: nil,
                details: OllamaTagDetails(
                    format: "system",
                    family: "apple-intelligence-adapter",
                    families: ["apple-intelligence", "foundation-model-adapter"],
                    parameter_size: nil,
                    quantization_level: nil
                )
            )
        }
        return OllamaTagsResponse(models: [baseModel] + adapters)
    }

    // MARK: - Private helpers

    private func makeChatResponse(
        request: ChatCompletionRequest,
        content: String,
        toolCalls: [OAIToolCall]? = nil,
        finishReason: String
    ) -> ChatCompletionResponse {
        ChatCompletionResponse(
            id: "chatcmpl_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: request.model,
            choices: [
                .init(
                    index: 0,
                    message: .init(role: "assistant", content: content, toolCalls: toolCalls),
                    finish_reason: finishReason
                )
            ],
            session_id: request.session_id
        )
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func generateClientToolDecision(request: ChatCompletionRequest, tools: [OAITool]) async throws -> ClientToolDecision {
        let systemModel = try systemLanguageModel(for: request.model)

        switch systemModel.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw NSError(
                domain: "FoundationModelsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model unavailable: \(String(describing: reason))"]
            )
        }

        let instructions = """
            You are the model behind an OpenAI-compatible coding-agent harness.
            The client, not afm-server, owns and executes the provided tools. Your job is to decide the next assistant turn.
            Use only the available client tool names. Never invent browser, navigation, or hidden tools.
            If the user asks about files, folders, terminal output, git state, builds, tests, or the local machine and a suitable client tool exists, choose tool_call instead of answering from memory.
            If tool results are already present and sufficient, choose answer and summarize the observed result.
            """
        let session = LanguageModelSession(
            model: systemModel,
            instructions: instructions
        )
        let options = GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: min(request.max_tokens ?? 512, 1024)
        )
        let rawPrompt = clientToolDecisionPrompt(request: request, tools: tools)
        let prompt = await contextBudgetedPrompt(
            rawPrompt,
            systemModel: systemModel,
            instructions: instructions,
            schema: ClientToolDecision.generationSchema,
            reserveResponseTokens: min(request.max_tokens ?? 512, 1024),
            label: "client-tools"
        )
        let response = try await session.respond(
            to: prompt,
            generating: ClientToolDecision.self,
            includeSchemaInPrompt: true,
            options: options
        )
        return response.content
    }
    private func makeClientToolCall(from decision: ClientToolDecision, request: ChatCompletionRequest, tools: [OAITool], toolChoice: ToolChoice) -> OAIToolCall? {
        let selectedName: String?
        switch toolChoice {
        case .function(let name):
            selectedName = name
        case .required:
            let decisionName = decision.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
            selectedName = decisionName.isEmpty ? preferredClientTool(for: request, tools: tools)?.name : decisionName
        case .auto:
            guard decision.action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "tool_call" else {
                return nil
            }
            selectedName = decision.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        case .none:
            return nil
        }

        guard let selectedName,
              let function = tools.compactMap(\.function).first(where: { $0.name == selectedName }) else {
            return nil
        }

        let arguments = repairedClientToolArgumentsJSON(
            decision.argumentsJSON,
            function: function,
            request: request
        )

        // In auto mode the on-device model over-triggers tools for conversational questions and
        // fabricates a "command" by echoing the user's prose (e.g. bash {"command":"tell me a
        // joke"}). If the chosen command tool's command isn't a plausible shell command, drop the
        // call so the request is answered instead of executed as a bogus command.
        if case .auto = toolChoice {
            if let commandKey = commandArgumentKey(for: function) {
                let command: String? = {
                    guard case .object(let object)? = jsonValue(fromJSONString: arguments),
                          case .string(let value)? = object[commandKey] else { return nil }
                    return value
                }()
                let plausibleCommand = command.map { looksLikeShellCommand($0) } ?? false
                // Drop the call when the command is empty/implausible, or when the request shows no
                // shell/file intent at all (the model hallucinates a valid-looking but irrelevant
                // command — e.g. "what's interesting about iOS" → bash ls ~/Developer).
                if !plausibleCommand || !requestHasToolIntent(for: request) {
                    logger.log("[tools] dropped command tool_call name=\(function.name, privacy: .public) command=\(command ?? "<none>", privacy: .public)")
                    return nil
                }
            } else if isFileReadFunction(function), !requestHasFileIntent(for: request) {
                // Conversational questions ("tell me a joke") shouldn't trigger a file read with a
                // fabricated path. Drop it when the request shows no file/read intent.
                logger.log("[tools] dropped spurious file-read tool_call name=\(function.name, privacy: .public) (no file intent)")
                return nil
            }
        }

        return OAIToolCall(
            id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            function: OAIFunctionCall(name: function.name, arguments: arguments)
        )
    }

    /// Whether a function is a file-reading tool: a path-like argument, no command argument,
    /// and a read-oriented name/description.
    private func isFileReadFunction(_ function: OAIFunction) -> Bool {
        guard commandArgumentKey(for: function) == nil else { return false }
        let properties = schemaProperties(function.parameters)
        let hasPath = ["path", "file", "file_path", "filepath", "filename"]
            .contains { propertyKey(named: $0, in: properties) != nil }
        guard hasPath else { return false }
        let nameAndDescription = "\(function.name) \(function.description ?? "")".lowercased()
        return textContainsAny(nameAndDescription, ["read", "open", "cat", "view", "contents", "file"])
    }

    /// Whether the latest user message expresses any intent to read/inspect files or paths.
    private func requestHasFileIntent(for request: ChatCompletionRequest) -> Bool {
        guard let raw = request.messages.last(where: { $0.role.lowercased() == "user" })?.content else {
            return false
        }
        let text = raw.lowercased()
        if textContainsAny(text, [
            "read", "open", "show", "view", "cat ", "file", "contents", "folder",
            "directory", "list", "path", "~/", "/users/", "./"
        ]) {
            return true
        }
        return requestReferencesSpecificFile(raw)
    }

    /// Whether the latest user message expresses intent that would warrant a shell/file tool
    /// (running commands, inspecting the repo/machine, or reading files). Used to suppress the
    /// model's tendency to fire a tool for purely conversational questions.
    private func requestHasToolIntent(for request: ChatCompletionRequest) -> Bool {
        if requestHasFileIntent(for: request) { return true }
        guard let text = request.messages.last(where: { $0.role.lowercased() == "user" })?.content.lowercased() else {
            return false
        }
        return textContainsAny(text, [
            "run ", "execute", "command", "terminal", "shell", "bash", "zsh", "script",
            "git", "npm", "npx", "node", "swift", "xcodebuild", "build", "compile", "test",
            "status", "branch", "commit", "push", "pull", "merge", "rebase", "clone", "fetch",
            "install", "grep", "search", "find", "pwd", "whoami", "date", "make", "brew",
            "process", "kill", "stdout", "stderr", "output", "repo", "repository"
        ])
    }

    /// Heuristic: does this string look like an actual shell command (vs. echoed prose/question)?
    /// Accepts paths and a known set of command binaries; rejects natural-language starters.
    private func looksLikeShellCommand(_ command: String) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasSuffix("?") else { return false }
        let firstToken = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? trimmed
        if firstToken.hasPrefix("/") || firstToken.hasPrefix("~") || firstToken.hasPrefix("./") { return true }
        let knownCommands: Set<String> = [
            "ls", "cat", "cd", "pwd", "echo", "grep", "rg", "find", "git", "npm", "npx", "node",
            "swift", "xcodebuild", "whoami", "date", "head", "tail", "wc", "du", "df", "ps", "kill",
            "mkdir", "rm", "cp", "mv", "touch", "open", "which", "env", "brew", "python", "python3",
            "pip", "pip3", "make", "curl", "wget", "chmod", "chown", "sed", "awk", "sort", "uniq",
            "diff", "tar", "zip", "unzip", "ssh", "scp", "docker", "kubectl", "tree", "stat", "less"
        ]
        return knownCommands.contains(firstToken.lowercased())
    }

    private func inferredClientToolCall(request: ChatCompletionRequest, tools: [OAITool], toolChoice: ToolChoice) -> OAIToolCall? {
        guard case .none = toolChoice else {
            if case .function(let forcedName) = toolChoice,
               let forced = tools.compactMap(\.function).first(where: { $0.name == forcedName }) {
                let arguments = repairedClientToolArgumentsJSON("{}", function: forced, request: request)
                return OAIToolCall(
                    id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                    function: OAIFunctionCall(name: forced.name, arguments: arguments)
                )
            }

            guard inferredShellCommand(for: request) != nil,
                  let function = preferredClientTool(for: request, tools: tools) else {
                return nil
            }
            let arguments = repairedClientToolArgumentsJSON("{}", function: function, request: request)
            return OAIToolCall(
                id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
                function: OAIFunctionCall(name: function.name, arguments: arguments)
            )
        }

        return nil
    }
    #endif

    private func clientToolDecisionPrompt(request: ChatCompletionRequest, tools: [OAITool]) -> String {
        let toolChoiceInstruction: String
        switch request.tool_choice ?? .auto {
        case .none:
            toolChoiceInstruction = "tool_choice is none: choose answer."
        case .auto:
            toolChoiceInstruction = "tool_choice is auto: choose either answer or one tool_call."
        case .required:
            toolChoiceInstruction = "tool_choice is required: choose one tool_call unless no valid tool can satisfy the request."
        case .function(let name):
            toolChoiceInstruction = "tool_choice forces the tool named \(name). If you call a tool, use exactly that name."
        }

        return truncatedForPrompt("""
        Decide the next assistant turn for this OpenAI-compatible tool-calling request.

        \(toolChoiceInstruction)

        Available client tools:
        \(toolCatalogPrompt(for: tools))

        Conversation:
        \(conversationTranscriptForTools(request.messages))

        Return a structured decision:
        - action: "tool_call" to request that the client execute a tool, or "answer" to respond directly.
        - toolName: exactly one available tool name when action is tool_call, otherwise empty.
        - argumentsJSON: one valid JSON object string matching the selected tool schema when action is tool_call, otherwise "{}".
        - For terminal, shell, bash, or command tools, argumentsJSON must include a non-empty command string. Example: {"command":"ls -la ~/Developer"}
        - answer: direct user-facing answer only when action is answer.
        """, limit: 14000)
    }

    private func toolCatalogPrompt(for tools: [OAITool]) -> String {
        let functions = tools.compactMap(\.function)
        let names = functions.map(\.name).joined(separator: ", ")
        var sections = ["Tool names: \(names)"]
        var usedCharacters = sections[0].count

        for function in functions.prefix(24) {
            let description = (function.description ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let schema = function.parameters.flatMap(jsonString(_:)) ?? "{\"type\":\"object\"}"
            let section = """

            - \(function.name)
              description: \(truncatedForPrompt(description.isEmpty ? "No description provided." : description, limit: 500))
              parameters: \(truncatedForPrompt(schema, limit: 1200))
            """
            guard usedCharacters + section.count <= 7000 else { break }
            sections.append(section)
            usedCharacters += section.count
        }

        return sections.joined(separator: "\n")
    }

    private func generateToolFinalAnswer(request: ChatCompletionRequest, tools: [OAITool]) async throws -> String {
        // Focus the answer on the CURRENT turn only. Feeding the small on-device model the
        // full flattened transcript (prior turns' tool dumps + summaries) makes it echo or
        // conflate stale output — e.g. answering "what's interesting about iOS" with a prior
        // directory listing, or summarizing `~` using leftover `~/Developer` content.
        let messages = request.messages
        let lastUserIndex = messages.lastIndex(where: { $0.role.lowercased() == "user" })
        let latestUser = (lastUserIndex.map { messages[$0].content } ?? messages.last?.content ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Collect only the tool results produced AFTER the last user message (this turn's output).
        var currentToolResults: [String] = []
        if let idx = lastUserIndex {
            for message in messages.suffix(from: messages.index(after: idx)) {
                let role = message.role.lowercased()
                if role == "tool" || role == "function" || role == "tool_result" {
                    let name = message.name.map { "\($0): " } ?? ""
                    currentToolResults.append("\(name)\(message.content)")
                }
            }
        }

        let prompt: String
        if currentToolResults.isEmpty {
            // No fresh tool output: answer the user's question directly, with no stale context.
            prompt = truncatedForPrompt(latestUser, limit: 12000)
        } else {
            let toolBlock = truncatedForPrompt(currentToolResults.joined(separator: "\n\n"), limit: 11000)
            prompt = """
            The user asked: \(latestUser)

            A tool was run to answer this. Its output:
            \(toolBlock)

            Answer the user's request using ONLY the tool output above. Summarize what is actually shown; do not invent entries, paths, or counts, and do not reference earlier requests. For directory listings, ignore "." and ".." entries unless the user explicitly asks about them. Do not output tool-call JSON or request another tool.
            """
        }
        return try await generateText(
            model: request.model,
            prompt: prompt,
            temperature: request.temperature,
            maxTokens: request.max_tokens
        )
    }

    private func shouldAnswerAfterClientToolResult(_ request: ChatCompletionRequest) -> Bool {
        let messages = request.messages
        guard let lastUserIndex = messages.lastIndex(where: { $0.role.lowercased() == "user" }) else {
            return false
        }

        var sawToolResultAfterLastUser = false
        var sawAssistantAnswerAfterToolResult = false

        for message in messages.suffix(from: messages.index(after: lastUserIndex)) {
            let role = message.role.lowercased()
            if role == "tool" || role == "function" || role == "tool_result" {
                sawToolResultAfterLastUser = true
                sawAssistantAnswerAfterToolResult = false
            } else if role == "assistant", sawToolResultAfterLastUser, !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sawAssistantAnswerAfterToolResult = true
            }
        }

        return sawToolResultAfterLastUser && !sawAssistantAnswerAfterToolResult
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func generateWithNativeFileTools(request: ChatCompletionRequest) async throws -> String {
        let systemModel = try systemLanguageModel(for: request.model)

        switch systemModel.availability {
        case .available:
            break
        case .unavailable(let reason):
            throw NSError(
                domain: "FoundationModelsService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Model unavailable: \(String(describing: reason))"]
            )
        }

        let instructions = """
        You are a helpful local assistant running in afm-server.
        Answer ordinary conversational questions directly.
        Use tools when the user asks for local machine facts, terminal commands, repo checks, builds, tests, or to inspect, list, read, write, edit, move, delete, or check files or folders on this Mac.
        For directory listings, repo checks, or terminal requests, prefer the bash tool so the answer is based on real stdout/stderr.
        Never answer questions about local files, folders, git state, command output, or this Mac from memory. Run a tool first.
        When the user refers to the Developer folder, use ~/Developer.
        Do not invent browser, web, or navigation tools. If a requested tool is unavailable, explain that briefly.
        """
        let tools = serverFileTools(for: request)
        let session = LanguageModelSession(
            model: systemModel,
            tools: tools,
            instructions: instructions
        )
        let options = GenerationOptions(
            temperature: request.temperature,
            maximumResponseTokens: request.max_tokens
        )
        let prompt = await contextBudgetedPrompt(
            nativeToolPrompt(from: request.messages),
            systemModel: systemModel,
            instructions: instructions,
            tools: tools,
            reserveResponseTokens: request.max_tokens ?? 1024,
            label: "native-tools"
        )
        let response = try await session.respond(
            to: prompt,
            options: options
        )
        logger.log("[tools] native Foundation Models response len=\(response.content.count)")
        return response.content
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func serverFileTools(for request: ChatCompletionRequest) -> [any Tool] {
        let text = nativeFileToolRequestText(from: request)
        var tools: [any Tool] = []
        var seen = Set<String>()

        func append(_ tool: any Tool) {
            if seen.insert(tool.name).inserted {
                tools.append(tool)
            }
        }

        if textContainsAny(text, [
            "terminal",
            "command",
            "run ",
            "execute",
            "shell",
            "bash",
            "zsh",
            "stdout",
            "stderr",
            "pwd",
            "whoami",
            "date ",
            "current date",
            "what date",
            "git ",
            "npm ",
            "swift ",
            "xcodebuild",
            "ls ",
            "rg ",
            "grep ",
            "find ",
            "what is in",
            "what's in",
            "developer"
        ]) {
            append(BashTerminalTool())
        }

        if textContainsAny(text, ["list", "contents", "what is in", "what's in", "ls ", "directory", "folder", "developer"]) {
            append(ListDirectoryTool())
            append(CheckPathTool())
        }

        if textContainsAny(text, ["read", "show", "cat ", "open file", "view file", "contents of"]) {
            append(ReadFileTool())
            append(CheckPathTool())
        }

        if textContainsAny(text, ["write", "save", "create file", "make file"]) {
            append(WriteFileTool())
            append(CreateDirectoryTool())
            append(CheckPathTool())
        }

        if textContainsAny(text, ["edit", "replace", "change in", "update file"]) {
            append(EditFileTool())
            append(ReadFileTool())
            append(CheckPathTool())
        }

        if textContainsAny(text, ["delete", "remove"]) {
            append(DeleteFileTool())
            append(CheckPathTool())
        }

        if textContainsAny(text, ["move", "rename"]) {
            append(MoveFileTool())
            append(CheckPathTool())
        }

        if tools.isEmpty {
            append(CheckPathTool())
            append(ListDirectoryTool())
            append(ReadFileTool())
        }

        return Array(tools.prefix(5))
    }
    #endif

    private func shouldOfferNativeFileTools(for request: ChatCompletionRequest) -> Bool {
        let text = nativeFileToolRequestText(from: request)
        return textContainsAny(text, [
            "file",
            "folder",
            "directory",
            "path",
            "developer",
            "~/",
            "/users/",
            "terminal",
            "command",
            "run ",
            "execute",
            "shell",
            "bash",
            "zsh",
            "stdout",
            "stderr",
            "pwd",
            "whoami",
            "date ",
            "current date",
            "what date",
            "git ",
            "npm ",
            "swift ",
            "xcodebuild",
            "ls ",
            "rg ",
            "grep ",
            "find ",
            "list",
            "contents",
            "read",
            "write",
            "edit",
            "delete",
            "remove",
            "move",
            "rename",
            "create"
        ])
    }

    private func nativeFileToolRequestText(from request: ChatCompletionRequest) -> String {
        let userText = request.messages
            .filter { $0.role.lowercased() == "user" }
            .suffix(2)
            .map(\.content)
            .joined(separator: "\n")
        return userText.lowercased()
    }

    private func textContainsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func localToolUnavailableMessage(error: Error) -> String {
        "I couldn't run the local terminal or file tool needed to answer that reliably: \(error.localizedDescription)"
    }

    private func conversationTranscriptForTools(_ messages: [ChatCompletionRequest.Message], limit: Int = 12000) -> String {
        var lines: [String] = []
        for message in messages.suffix(14) {
            let role = message.role.lowercased()
            switch role {
            case "assistant":
                if !message.content.isEmpty {
                    lines.append("assistant: \(message.content)")
                }
                if let toolCalls = message.tool_calls, !toolCalls.isEmpty {
                    for call in toolCalls {
                        lines.append("assistant tool_call id=\(call.id) name=\(call.function.name) arguments=\(call.function.arguments)")
                    }
                }
            case "tool", "function", "tool_result":
                let id = message.tool_call_id.map { " id=\($0)" } ?? ""
                let name = message.name.map { " name=\($0)" } ?? ""
                lines.append("tool result\(id)\(name): \(message.content)")
            default:
                lines.append("\(role): \(message.content)")
            }
        }
        return truncatedForPrompt(lines.joined(separator: "\n"), limit: limit)
    }

    private func nativeToolPrompt(from messages: [ChatCompletionRequest.Message]) -> String {
        let lastUser = messages.last(where: { $0.role.lowercased() == "user" })?.content ?? messages.last?.content ?? ""
        let priorMessages = messages
            .dropLast()
            .filter { $0.role.lowercased() != "system" }
            .suffix(8)
            .map { "\($0.role): \($0.content)" }
            .joined(separator: "\n")

        if priorMessages.isEmpty {
            return truncatedForPrompt(lastUser, limit: 12000)
        }

        return truncatedForPrompt("""
        Conversation so far:
        \(priorMessages)

        User request:
        \(lastUser)
        """, limit: 12000)
    }

    private func truncatedForPrompt(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = text.prefix(limit / 2)
        let tail = text.suffix(limit / 2)
        return "\(head)\n...\n\(tail)"
    }

    // Serialize JSONValue to a compact string
    private func jsonString(_ v: JSONValue) -> String? {
        func encode(_ v: JSONValue) -> Any {
            switch v {
            case .string(let s): return s
            case .number(let d): return d
            case .bool(let b): return b
            case .null: return NSNull()
            case .object(let o): return o.mapValues { encode($0) }
            case .array(let a): return a.map { encode($0) }
            }
        }
        let any = encode(v)
        guard JSONSerialization.isValidJSONObject(any) else { return nil }
        if let data = try? JSONSerialization.data(withJSONObject: any, options: []) {
            return String(data: data, encoding: .utf8)
        }
        return nil
    }

    private func jsonValue(fromJSONString string: String) -> JSONValue? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func repairedClientToolArgumentsJSON(_ rawValue: String, function: OAIFunction, request: ChatCompletionRequest) -> String {
        var arguments = normalizedArgumentsObject(rawValue)

        if let commandKey = commandArgumentKey(for: function),
           !hasNonEmptyString(arguments[commandKey]),
           let command = inferredShellCommand(for: request) {
            arguments[commandKey] = .string(command)
        }

        if let workingDirectoryKey = workingDirectoryArgumentKey(for: function),
           !hasNonEmptyString(arguments[workingDirectoryKey]) {
            arguments[workingDirectoryKey] = .string("~")
        }

        return jsonString(.object(arguments)) ?? "{}"
    }

    private func normalizedArgumentsObject(_ rawValue: String) -> [String: JSONValue] {
        let normalized = normalizedArgumentsJSON(rawValue)
        guard case .object(let object)? = jsonValue(fromJSONString: normalized) else {
            return [:]
        }
        return object
    }

    private func normalizedArgumentsJSON(_ rawValue: String) -> String {
        var text = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.hasPrefix("```") {
            let lines = text.components(separatedBy: .newlines)
            let unfenced = lines
                .dropFirst()
                .dropLast(lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true ? 1 : 0)
                .joined(separator: "\n")
            text = unfenced.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start <= end {
            text = String(text[start...end])
        }

        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              object is [String: Any],
              let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let normalizedString = String(data: normalized, encoding: .utf8) else {
            return "{}"
        }

        return normalizedString
    }

    private func commandArgumentKey(for function: OAIFunction) -> String? {
        let directCandidates = ["command", "cmd", "shell_command", "bash_command"]
        let terminalFallbackCandidates = directCandidates + ["input", "code", "script"]
        let properties = schemaProperties(function.parameters)
        let required = schemaRequiredKeys(function.parameters)

        for key in required where directCandidates.contains(key.lowercased()) && isStringSchema(properties[key]) {
            return key
        }

        for key in directCandidates {
            if let propertyKey = propertyKey(named: key, in: properties), isStringSchema(properties[propertyKey]) {
                return propertyKey
            }
        }

        if functionMentionsTerminal(function) {
            for key in required where terminalFallbackCandidates.contains(key.lowercased()) && isStringSchema(properties[key]) {
                return key
            }
            if let propertyKey = properties.keys.first(where: { terminalFallbackCandidates.contains($0.lowercased()) && isStringSchema(properties[$0]) }) {
                return propertyKey
            }
            // Do NOT fall back to a synthetic "command" key: a tool that only *mentions* terminal
            // words in its description but has no command-like property (e.g. `read`, whose
            // description contains "truncated") is not a command tool. Returning "command" here
            // made the server emit read({"command": "ls ..."}), which clients reject.
        }

        return nil
    }

    /// Whole-word match of terminal/command intent in a tool's name+description. Uses word
    /// boundaries so "run" does not match inside "truncated" and "exec" not inside "execute"-only.
    private func functionMentionsTerminal(_ function: OAIFunction) -> Bool {
        let text = "\(function.name) \(function.description ?? "")".lowercased()
        let tokens = Set(text.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
        let terminalWords: Set<String> = [
            "terminal", "shell", "bash", "zsh", "sh", "command", "commands", "cmd",
            "exec", "execute", "run", "running", "process", "subprocess"
        ]
        return !tokens.isDisjoint(with: terminalWords)
    }

    private func preferredClientTool(for request: ChatCompletionRequest, tools: [OAITool]) -> OAIFunction? {
        let functions = tools.compactMap(\.function)
        guard inferredShellCommand(for: request) != nil else {
            return functions.first
        }

        if let terminalFunction = functions.first(where: { commandArgumentKey(for: $0) != nil }) {
            return terminalFunction
        }

        return functions.first { functionMentionsTerminal($0) }
    }

    private func propertyKey(named name: String, in properties: [String: JSONValue]) -> String? {
        if properties.keys.contains(name) { return name }
        return properties.keys.first { $0.lowercased() == name.lowercased() }
    }

    private func workingDirectoryArgumentKey(for function: OAIFunction) -> String? {
        let candidates = ["working_directory", "workingdirectory", "workingdir", "workdir", "cwd", "directory"]
        let properties = schemaProperties(function.parameters)
        let required = schemaRequiredKeys(function.parameters)

        for key in required where candidates.contains(key.lowercased()) && isStringSchema(properties[key]) {
            return key
        }

        for key in candidates {
            if let propertyKey = propertyKey(named: key, in: properties), isStringSchema(properties[propertyKey]) {
                return propertyKey
            }
        }

        return nil
    }

    private func schemaProperties(_ schema: JSONValue?) -> [String: JSONValue] {
        guard case .object(let root)? = schema else { return [:] }
        if case .object(let properties)? = root["properties"] {
            return properties
        }
        if case .object(let inputSchema)? = root["input_schema"],
           case .object(let properties)? = inputSchema["properties"] {
            return properties
        }
        if case .object(let inputSchema)? = root["inputSchema"],
           case .object(let properties)? = inputSchema["properties"] {
            return properties
        }
        return [:]
    }

    private func schemaRequiredKeys(_ schema: JSONValue?) -> [String] {
        guard case .object(let root)? = schema else { return [] }
        if case .array(let required)? = root["required"] {
            return required.compactMap { value in
                guard case .string(let key) = value else { return nil }
                return key
            }
        }
        if case .object(let inputSchema)? = root["input_schema"],
           case .array(let required)? = inputSchema["required"] {
            return required.compactMap { value in
                guard case .string(let key) = value else { return nil }
                return key
            }
        }
        if case .object(let inputSchema)? = root["inputSchema"],
           case .array(let required)? = inputSchema["required"] {
            return required.compactMap { value in
                guard case .string(let key) = value else { return nil }
                return key
            }
        }
        return []
    }

    private func isStringSchema(_ schema: JSONValue?) -> Bool {
        guard case .object(let object)? = schema else { return true }
        if case .string(let type)? = object["type"] {
            return type == "string"
        }
        if case .array(let types)? = object["type"] {
            return types.contains { value in
                guard case .string(let type) = value else { return false }
                return type == "string"
            }
        }
        return true
    }

    private func hasNonEmptyString(_ value: JSONValue?) -> Bool {
        guard case .string(let string)? = value else { return false }
        return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func inferredShellCommand(for request: ChatCompletionRequest) -> String? {
        guard let userMessage = request.messages.last(where: { $0.role.lowercased() == "user" })?.content else {
            return nil
        }
        let text = userMessage.lowercased()

        // Don't synthesize a directory `ls` when the user clearly wants to READ a file rather than
        // list a folder. Otherwise a path that merely contains a known directory (e.g.
        // "read the README in ~/Developer/afm-server") gets hijacked into "ls -la ~/Developer".
        // Defer those to the model's file-read tool.
        let hasListingIntent = textContainsAny(text, ["what's in", "what is in", "whats in", "list ", "contents of", "ls "])
        let wantsFileRead = textContainsAny(text, ["read ", "open ", "cat ", "view "])
        let refersToFolder = textContainsAny(text, ["folder", "directory"])
        if !hasListingIntent && !refersToFolder && (wantsFileRead || requestReferencesSpecificFile(userMessage)) {
            return nil
        }

        if textContainsAny(text, ["developer folder", "developer directory", "~/developer", "what is in my developer", "what's in my developer"]) {
            if textContainsAny(text, ["top-level", "top level", "names", "just the names", "list just"]) {
                return "ls -1 ~/Developer"
            }
            return "ls -la ~/Developer"
        }

        if textContainsAny(text, ["desktop folder", "desktop directory", "~/desktop", "what is in my desktop", "what's in my desktop"]) {
            return "ls -la ~/Desktop"
        }

        if textContainsAny(text, ["documents folder", "documents directory", "~/documents", "what is in my documents", "what's in my documents"]) {
            return "ls -la ~/Documents"
        }

        if textContainsAny(text, ["current directory", "working directory", "print working directory", "pwd"]) {
            return "pwd"
        }

        if textContainsAny(text, ["whoami", "who am i logged in as"]) {
            return "whoami"
        }

        if textContainsAny(text, ["current date", "what date", "date and time"]) {
            return "date"
        }

        if text.contains("git status") {
            return "git status --short"
        }

        if text.contains("ls -1 ~/developer") {
            return "ls -1 ~/Developer"
        }

        if text.contains("ls -la ~/developer") || text.contains("ls -l ~/developer") {
            return "ls -la ~/Developer"
        }

        // Generic "what's in <path>" / "list <path>" / "contents of <path>" → list that path.
        // Only fires when the target resolves to an explicit path-like token (~, ~/…, /…, "home"),
        // so non-filesystem uses of "list" (e.g. "list the benefits of X") fall through.
        let listTriggers = [
            "what's in ", "what is in ", "whats in ", "what files are in ",
            "contents of ", "list the contents of ", "list contents of ",
            "show me what's in ", "show me what is in ", "show the contents of ",
            "list "
        ]
        for trigger in listTriggers {
            guard let triggerRange = text.range(of: trigger) else { continue }
            var rest = String(userMessage[triggerRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let breakRange = rest.rangeOfCharacter(from: CharacterSet(charactersIn: "\n.?!,;")) {
                rest = String(rest[..<breakRange.lowerBound])
            }
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: "`\"' "))
            if let path = shellPathToken(from: rest) {
                return "ls -la \(path)"
            }
        }

        let runPrefixes = ["run exactly:", "run exactly ", "run command:", "run "]
        for prefix in runPrefixes {
            guard let runRange = text.range(of: prefix) else { continue }
            var command = userMessage[runRange.upperBound...]
                .split(separator: "\n", maxSplits: 1)
                .first
                .map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let sentenceBreak = command?.range(of: ". ") {
                command = String(command?[..<sentenceBreak.lowerBound] ?? "")
            }
            command = command?
                .trimmingCharacters(in: CharacterSet(charactersIn: "`\"' "))

            if let command, !command.isEmpty, command.count <= 200 {
                if command.lowercased().contains("ls -1 ~/developer") {
                    return "ls -1 ~/Developer"
                }
                return command
            }
        }

        return nil
    }

    /// Resolve a path-like token (for `ls`) from free text, or nil if it isn't clearly a path.
    /// Accepts `~`, `~/…`, absolute `/…`, and the words "home"/"home folder"/"home directory".
    private func shellPathToken(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lower = trimmed.lowercased()
        let homePhrases: Set<String> = [
            "home", "my home", "the home", "home folder", "home directory",
            "my home folder", "my home directory", "the home folder", "the home directory"
        ]
        if homePhrases.contains(lower) { return "~" }

        // Use the first whitespace-delimited token for path-like inputs.
        let token = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        guard token == "~" || token.hasPrefix("~/") || token.hasPrefix("/") else { return nil }
        return sanitizedShellPath(token)
    }

    /// Whether the text contains a path token pointing at a specific file, i.e. whose final
    /// component has a file extension (e.g. `~/Developer/afm-server/README.md`, `package.json`).
    private func requestReferencesSpecificFile(_ text: String) -> Bool {
        for rawToken in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'(),"))
            guard token.contains("/") || token.contains(".") else { continue }
            let last = token.split(separator: "/").last.map(String.init) ?? token
            // A real extension: a dot that is not leading (so ".gitignore" stays a dir-ish hidden
            // file, but "README.md"/"package.json" count) and is followed by 1–5 letters/digits.
            guard let dotIndex = last.lastIndex(of: "."), dotIndex != last.startIndex else { continue }
            let ext = last[last.index(after: dotIndex)...]
            if (1...5).contains(ext.count) && ext.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return true
            }
        }
        return false
    }

    /// Allow only safe path characters so we never synthesize an injectable command.
    private func sanitizedShellPath(_ token: String) -> String? {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~/-"
        )
        guard token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return token
    }

    /// If the model chose a file-reading tool but the target is a directory, redirect to a
    /// directory listing via the client's terminal tool. Reading a directory as a file makes
    /// Node-based harnesses throw "EISDIR: illegal operation on a directory, read".
    private func redirectedDirectoryRead(_ toolCall: OAIToolCall, request: ChatCompletionRequest, tools: [OAITool]) -> OAIToolCall? {
        let functions = tools.compactMap(\.function)
        guard let function = functions.first(where: { $0.name == toolCall.function.name }) else { return nil }

        // Only consider file-reader tools: a path-like argument, no command argument, read-ish name.
        guard commandArgumentKey(for: function) == nil else { return nil }
        let properties = schemaProperties(function.parameters)
        let pathKey = ["path", "file", "file_path", "filepath", "filename"]
            .compactMap { propertyKey(named: $0, in: properties) }
            .first { isStringSchema(properties[$0]) }
        guard let pathKey else { return nil }
        let nameAndDescription = "\(function.name) \(function.description ?? "")".lowercased()
        guard textContainsAny(nameAndDescription, ["read", "open", "cat", "view", "contents", "file"]) else { return nil }

        // Extract the path the model produced.
        guard case .object(let arguments)? = jsonValue(fromJSONString: toolCall.function.arguments),
              case .string(let rawPath)? = arguments[pathKey] else { return nil }
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, pathIsDirectory(path, request: request) else { return nil }

        // Need a terminal tool and a safe path to list with.
        guard let terminal = functions.first(where: { commandArgumentKey(for: $0) != nil }),
              let commandKey = commandArgumentKey(for: terminal),
              let safePath = sanitizedShellPath(path) else { return nil }

        let listArguments = jsonString(.object([commandKey: .string("ls -la \(safePath)")])) ?? "{\"\(commandKey)\":\"ls -la \(safePath)\"}"
        return OAIToolCall(
            id: "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: ""),
            function: OAIFunctionCall(name: terminal.name, arguments: listArguments)
        )
    }

    /// Whether a path refers to a directory. For `~`/absolute paths we check the real filesystem
    /// (the server runs locally); otherwise fall back to a text heuristic.
    private func pathIsDirectory(_ path: String, request: ChatCompletionRequest) -> Bool {
        if path.hasSuffix("/") { return true }

        var expanded = path
        if expanded == "~" {
            expanded = NSHomeDirectory()
        } else if expanded.hasPrefix("~/") {
            expanded = NSHomeDirectory() + String(expanded.dropFirst(1))
        }
        if expanded.hasPrefix("/") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) {
                return isDirectory.boolValue
            }
            return false
        }

        // Relative/unresolvable path: treat as a directory only if the request says so and the
        // final component has no file extension.
        let text = (request.messages.last(where: { $0.role.lowercased() == "user" })?.content ?? "").lowercased()
        let mentionsFolder = textContainsAny(text, ["folder", "directory"])
        let lastComponent = path.split(separator: "/").last.map(String.init) ?? path
        return mentionsFolder && !lastComponent.contains(".")
    }

    // Replace this with actual Foundation Models generation when available in your target.
    private func generateText(model: String, prompt: String, temperature: Double?, maxTokens: Int?) async throws -> String {
        // Prefer Apple Intelligence on supported platforms; otherwise return a graceful fallback
        logger.log("Generating text (FoundationModels if available, else fallback)")
        AppLog.debug("Generating text with \(model)", source: "model")

        #if canImport(FoundationModels)
        logger.log("[fm] FoundationModels framework is available at compile time")
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            logger.log("[fm] Runtime availability check passed - attempting to use FoundationModels")
            do {
                return try await generateWithFoundationModels(model: model, prompt: prompt, temperature: temperature, maxTokens: maxTokens)
            } catch {
                logger.error("FoundationModels failed: \(String(describing: error))")
                AppLog.error("Foundation Models generation failed: \(error.localizedDescription)", source: "model")
                // Fall through to fallback message below without truncating the prompt
            }
        } else {
            logger.warning("[fm] Runtime availability check FAILED - macOS 26.0+ required. Current OS version does not meet requirements.")
            AppLog.warning("Foundation Models runtime unavailable on this OS", source: "model")
        }
        #else
        logger.warning("[fm] FoundationModels framework NOT available at compile time")
        AppLog.warning("Foundation Models framework not available at compile time", source: "model")
        #endif

        // Fallback path when FoundationModels is not available on this platform/SDK.
        let trimmed = prompt.split(separator: "\n").last.map(String.init) ?? prompt
        let fallback = "(Local fallback) Apple Intelligence unavailable: returning a synthetic response. Based on your prompt, here's an echo: \(trimmed.replacingOccurrences(of: "assistant:", with: "").trimmingCharacters(in: .whitespaces)))"
        return fallback
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func systemLanguageModel(for model: String) throws -> SystemLanguageModel {
        guard let adapter = FoundationModelAdapterRegistry.adapter(forModelID: model) else {
            return .default
        }

        let adapterURL = FoundationModelAdapterRegistry.fileURL(for: adapter)
        let systemAdapter = try SystemLanguageModel.Adapter(fileURL: adapterURL)
        return SystemLanguageModel(adapter: systemAdapter)
    }

    private func streamingSessionKey(model: String, sessionID: String) -> String {
        "\(model)::\(sessionID)"
    }

    @available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
    private func generateWithFoundationModels(model: String, prompt: String, temperature: Double?, maxTokens: Int?) async throws -> String {
        // Use the system-managed on-device language model
        let systemModel = try systemLanguageModel(for: model)

        // Check availability and provide descriptive errors for callers
        switch systemModel.availability {
        case .available:
            break
        case .unavailable(.deviceNotEligible):
            throw NSError(domain: "FoundationModelsService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Device not eligible for Apple Intelligence."])
        case .unavailable(.appleIntelligenceNotEnabled):
            throw NSError(domain: "FoundationModelsService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Apple Intelligence is not enabled. Please enable it in Settings."])
        case .unavailable(.modelNotReady):
            throw NSError(domain: "FoundationModelsService", code: 3, userInfo: [NSLocalizedDescriptionKey: "Model not ready (e.g., downloading). Try again later."])
        case .unavailable(let other):
            throw NSError(domain: "FoundationModelsService", code: 4, userInfo: [NSLocalizedDescriptionKey: "Model unavailable: \(String(describing: other))"])
        }

        // Lean instructions only — no model identifiers or temperature text.
        // Matches the Perspective Chat pattern: minimal instructions to avoid guardrail triggers.
        let instructions = "You are a helpful assistant."

        // Create a short-lived session for this request
        let session = LanguageModelSession(model: systemModel, instructions: instructions)
        let budgetedPrompt = await contextBudgetedPrompt(
            prompt,
            systemModel: systemModel,
            instructions: instructions,
            reserveResponseTokens: maxTokens ?? 1024,
            label: "text"
        )
        let options = GenerationOptions(
            temperature: temperature,
            maximumResponseTokens: maxTokens
        )

        logger.log("[fm] requesting response len=\(budgetedPrompt.count)")
        do {
            let response = try await session.respond(to: budgetedPrompt, options: options)
            logger.log("[fm] got response len=\(response.content.count)")
            AppLog.info("Foundation Models response completed (\(response.content.count) chars)", source: "model")
            return response.content
        } catch {
            let errorDesc = String(reflecting: error).lowercased()
            if errorDesc.contains("guardrailviolation") || errorDesc.contains("refusal") {
                logger.warning("[fm] Guardrail/refusal hit — returning friendly message")
                AppLog.warning("Foundation Models guardrail/refusal encountered", source: "model")
                return "I'm not able to help with that particular request. Could you try rephrasing or asking something different?"
            }
            throw error
        }
    }
    
    #endif

    // MARK: - Models inventory

    private func availableModels() -> [OpenAIModel] {
        // Keep the base model stable, then append user-loaded adapters as selectable model IDs.
        let baseModel = OpenAIModel(
            id: "apple.local",
            object: "model",
            created: createdEpoch,
            owned_by: "system"
        )
        let adapterModels = FoundationModelAdapterRegistry.loadRecords().map { adapter in
            OpenAIModel(
                id: adapter.modelID,
                object: "model",
                created: Int(adapter.addedAt.timeIntervalSince1970),
                owned_by: "system-adapter"
            )
        }
        return [baseModel] + adapterModels
    }
}

// MARK: - Multi-segment chat generation (optional)

extension FoundationModelsService {
    /// Generate a long-form response in multiple segments by chaining short sessions.
    /// Each segment is streamed back via the `emit` callback as soon as it's generated.
    func generateChatSegments(messages: [ChatCompletionRequest.Message], model: String, temperature: Double?, segmentChars: Int = 900, maxSegments: Int = 4, emit: @escaping (String) async -> Void) async throws {
        await inferenceSemaphore.acquire()
        defer { Task { await inferenceSemaphore.release() } }
        // Prepare initial prompt within context budget
        let basePrompt = await prepareChatPrompt(messages: messages, model: model, temperature: temperature, maxTokens: nil)
        let tokens = approxTokenCount(basePrompt)
        logger.log("[chat.multi] basePromptLen=\(basePrompt.count) tokens=\(tokens) segChars=\(segmentChars) maxSeg=\(maxSegments)")
        var soFar = ""

        // Helper to build instructions for each segment
        func instructions(forRound round: Int) -> String {
            var parts: [String] = []
            parts.append("You are a helpful assistant. Continue the answer succinctly and cohesively.")
            parts.append("Aim for about \(segmentChars) characters in this segment; do not repeat prior content.")
            if round > 1 {
                parts.append("So far, you've written the following (do not repeat, only continue):\n\(soFar.suffix(1500))")
            }
            return parts.joined(separator: "\n")
        }

        // First segment uses the full prepared prompt
        for round in 1...maxSegments {
            let prompt: String
            if round == 1 {
                prompt = basePrompt
            } else {
                prompt = "\(basePrompt)\n\nassistant:"
            }

            do {
                #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
                    // Create a fresh short-lived session per segment with tailored instructions
                    let systemModel = try self.systemLanguageModel(for: model)
                    let session = LanguageModelSession(model: systemModel, instructions: instructions(forRound: round))
                    let response = try await session.respond(to: prompt)
                    let segment = response.content
                    logger.log("[chat.multi] round=\(round) segLen=\(segment.count)")
                    if !segment.isEmpty {
                        soFar += segment
                        await emit(segment)
                    }
                } else {
                    let segment = try await self.generateText(model: model, prompt: instructions(forRound: round) + "\n\n" + prompt, temperature: temperature, maxTokens: nil)
                    logger.log("[chat.multi] round=\(round) segLen=\(segment.count)")
                    if !segment.isEmpty {
                        soFar += segment
                        await emit(segment)
                    }
                }
                #else
                let segment = try await self.generateText(model: model, prompt: instructions(forRound: round) + "\n\n" + prompt, temperature: temperature, maxTokens: nil)
                logger.log("[chat.multi] round=\(round) segLen=\(segment.count)")
                if !segment.isEmpty {
                    soFar += segment
                    await emit(segment)
                }
                #endif
            } catch {
                // Propagate error so caller can send a friendly fallback and finalize the stream
                throw error
            }

            // Heuristic stop: if the last segment is short, assume completion
            if soFar.count >= segmentChars * (round - 1) + Int(Double(segmentChars) * 0.6) {
                // continue
            } else {
                break
            }
        }
    }
}
