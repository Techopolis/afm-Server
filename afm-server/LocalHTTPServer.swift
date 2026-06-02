import Foundation
import Network
import OSLog

actor LocalHTTPServer {
    static let shared = LocalHTTPServer()

    private let logger = Logger(subsystem: "online.techopolis.afm-server", category: "LocalHTTPServer")
    private var listener: NWListener?
    private var connections: Set<ConnectionWrapper> = []

    var port: UInt16 = 11434
    private(set) var isRunning: Bool = false
    private(set) var lastError: String? = nil
    private var activeRequestCount: Int = 0

    /// Ports to try in order if the primary port is unavailable.
    /// Keep fallback in a dedicated local API range to avoid common dev ports.
    private let fallbackPorts: [UInt16] = [
        11434, 11435, 11436, 11437, 11438, 11439,
        11440, 11441, 11442, 11443, 11444
    ]
    private var portsToTry: [UInt16] = []
    private var currentPortIndex: Int = 0

    // MARK: - Security
    //
    // Security model:
    // 1. Loopback-only binding keeps the server local to this Mac.
    // 2. A user-configurable API key is required for non-preflight API requests.
    // 3. Host, origin, and client allowlists are optional policy layers and
    //    are not required to use the local API.

    /// API key accepted through the OpenAI-compatible Authorization header for all non-preflight requests.
    private var authToken: String?

    static let minimumAuthTokenLength = 5
    static let authTokenDefaultsKey = "apiKey"

    private init() {}

    func incrementActiveRequests() -> Int {
        activeRequestCount += 1
        return activeRequestCount
    }

    func decrementActiveRequests() -> Int {
        activeRequestCount -= 1
        return activeRequestCount
    }

    func getActiveRequestCount() -> Int {
        activeRequestCount
    }

    // MARK: - Security helpers

    nonisolated static func normalizedAuthToken(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func authTokenValidationMessage(for token: String) -> String? {
        let normalized = normalizedAuthToken(token)
        guard normalized.count >= minimumAuthTokenLength else {
            return "API key must be more than 4 characters."
        }
        guard normalized.rangeOfCharacter(from: .newlines) == nil else {
            return "API key cannot contain line breaks."
        }
        return nil
    }

    nonisolated static func isValidAuthToken(_ token: String) -> Bool {
        authTokenValidationMessage(for: token) == nil
    }

    private func loadOrCreateAuthToken() throws {
        if let storedToken = Self.readAuthTokenFromUserDefaults() {
            authToken = storedToken
            logger.log("Loaded API key from UserDefaults")
            AppLog.info("Loaded API key", source: "auth")
            return
        }

        try generateAndStoreToken()
    }

    /// Generate a cryptographic API key and store it in UserDefaults.
    @discardableResult
    private func generateAndStoreToken() throws -> String {
        let token = UUID().uuidString
        try storeAuthToken(token)
        return token
    }

    private func storeAuthToken(_ token: String) throws {
        let normalizedToken = Self.normalizedAuthToken(token)
        if let validationMessage = Self.authTokenValidationMessage(for: normalizedToken) {
            throw NSError(
                domain: "LocalHTTPServer",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: validationMessage]
            )
        }

        authToken = nil

        Self.writeAuthTokenToUserDefaults(normalizedToken)
        guard Self.readAuthTokenFromUserDefaults() == normalizedToken else {
            throw NSError(
                domain: "LocalHTTPServer",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Persisted API key did not match saved value"]
            )
        }

        authToken = normalizedToken

        logger.log("API key saved to UserDefaults")
        AppLog.info("API key saved", source: "auth")
    }

    nonisolated static func readStoredAuthToken() -> String? {
        readAuthTokenFromUserDefaults()
    }

    private nonisolated static func readAuthTokenFromUserDefaults() -> String? {
        guard let token = UserDefaults.standard.string(forKey: authTokenDefaultsKey)
            .map(normalizedAuthToken),
              isValidAuthToken(token) else {
            return nil
        }
        return token
    }

    private nonisolated static func writeAuthTokenToUserDefaults(_ token: String) {
        UserDefaults.standard.set(token, forKey: authTokenDefaultsKey)
    }

    nonisolated private static func corsOrigin(for origin: String?) -> String {
        origin ?? ""
    }

    nonisolated private static func jsonHeaders(corsOrigin: String? = nil) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        if let corsOrigin, !corsOrigin.isEmpty {
            headers["Access-Control-Allow-Origin"] = corsOrigin
            headers["Vary"] = "Origin"
        }
        return headers
    }

    /// Return the current API key (for UI display / copy-to-clipboard).
    func getAuthToken() -> String? {
        if let authToken {
            return authToken
        }
        return Self.readStoredAuthToken()
    }

    func setAuthToken(_ token: String) throws {
        try storeAuthToken(token)
    }

    @discardableResult
    func rotateAuthToken() throws -> String {
        try generateAndStoreToken()
    }

    // MARK: Lifecycle

    func start() async {
        guard !isRunning else {
            logger.log("Server already running, ignoring start request")
            AppLog.warning("Start requested while server is already running", source: "server")
            return
        }
        lastError = nil
        do {
            try loadOrCreateAuthToken()
        } catch {
            authToken = nil
            lastError = "Failed to persist API key: \(error.localizedDescription)"
            logger.error("\(self.lastError ?? "")")
            AppLog.error(lastError ?? "Failed to persist API key", source: "auth")
            return
        }
        // Build port list: configured port first, then fallbacks (deduped)
        portsToTry = [port] + fallbackPorts.filter { $0 != port }
        currentPortIndex = 0
        await tryStartOnNextPort()
    }
    
    /// Attempts to start the server on the next available port in the list
    private func tryStartOnNextPort() async {
        guard currentPortIndex < portsToTry.count else {
            lastError = "Failed to start server: all ports in use (tried: \(portsToTry.map(String.init).joined(separator: ", ")))"
            logger.error("\\(self.lastError ?? \"\")")
            AppLog.error(lastError ?? "Failed to start server: all ports in use", source: "server")
            return
        }

        let targetPort = portsToTry[currentPortIndex]
        self.port = targetPort
        
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: targetPort)!)
            listener?.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { await self.handleListenerState(state, currentPort: targetPort) }
            }
            listener?.newConnectionHandler = { [weak self] newConn in
                guard let self else { return }
                Task { await self.accept(newConn) }
            }
            listener?.start(queue: DispatchQueue.global())
            logger.log("Server starting on port \(targetPort)...")
            AppLog.info("Starting local HTTP server on port \(targetPort)", source: "server")
        } catch {
            lastError = "Failed to create listener on port \(targetPort): \(error.localizedDescription)"
            logger.error("Failed to start listener: \(String(describing: error))")
            AppLog.warning("Port \(targetPort) unavailable: \(error.localizedDescription)", source: "server")
            // Try next port
            currentPortIndex += 1
            await tryStartOnNextPort()
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        isRunning = false
        AppLog.info("Local HTTP server stopped", source: "server")
    }

    // MARK: Request handling

    nonisolated func handleRequest(_ request: HTTPRequest) async -> ServerResponse {
        // Correlate logs for this request
        let rid = String(UUID().uuidString.prefix(8))
        let logger = Logger(subsystem: "online.techopolis.afm-server", category: "LocalHTTPServer")

        let _ = await self.incrementActiveRequests()
        defer { Task { let _ = await self.decrementActiveRequests() } }

        await ServerMetrics.shared.recordRequest()

        let origin = request.headers["origin"]
        let corsOrigin = Self.corsOrigin(for: origin)

        // CORS preflight support (no API key required for preflight)
        if request.method == "OPTIONS" {
            return .normal(HTTPResponse(status: 204, headers: [
                "Access-Control-Allow-Origin": corsOrigin,
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS, HEAD",
                "Access-Control-Allow-Headers": "Content-Type, Authorization, Accept",
                "Access-Control-Max-Age": "600"
            ], body: Data()))
        }

        // API key bearer auth is the required API access control. Hosts, origins, and
        // client allowlists are optional policy layers and are not required here.
        if let token = await self.authToken {
            let authHeader = request.headers["authorization"] ?? request.headers["Authorization"] ?? ""
            let provided = authHeader.hasPrefix("Bearer ") ? String(authHeader.dropFirst(7)) : ""
            if provided != token {
                logger.warning("[req:\(rid, privacy: .public)] Blocked: invalid or missing API key")
                AppLog.warning("Blocked request with invalid or missing API key", source: "auth")
                let msg = ["error": ["message": "Unauthorized: invalid or missing API key. Set or copy the API key in afm-server Settings."]]
                let data = (try? JSONSerialization.data(withJSONObject: msg, options: [])) ?? Data()
                return .normal(HTTPResponse(status: 401, headers: Self.jsonHeaders(corsOrigin: corsOrigin), body: data))
            }
        }

        // Normalize path: strip query string and trailing slash
        let basePath: String = {
            if let q = request.path.firstIndex(of: "?") { return String(request.path[..<q]) }
            return request.path
        }()
        let path: String = {
            if basePath.count > 1 && basePath.hasSuffix("/") { return String(basePath.dropLast()) }
            return basePath
        }()

        // Basic request logging for troubleshooting
        let contentType = request.headers["content-type"] ?? request.headers["Content-Type"] ?? ""
        let contentLength = request.headers["content-length"] ?? request.headers["Content-Length"] ?? ""
        logger.log("[req:\(rid, privacy: .public)] HTTP \(request.method, privacy: .public) \(path, privacy: .public) ct=\(contentType, privacy: .public) cl=\(contentLength, privacy: .public)")
        AppLog.debug("\(request.method) \(path)", source: "http")
        if request.method == "POST" {
            logger.log("[req:\(rid, privacy: .public)] body: \(Self.truncateBodyForLog(request.bodyData), privacy: .public)")
        }

        // Route GET /v1/models (list)
        if (request.method == "GET" || request.method == "HEAD") && path == "/v1/models" {
            do {
                let models = FoundationModelsService.shared.listModels()
                let data = try JSONEncoder().encode(models)
                let resp = HTTPResponse(status: 200, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data)
                if request.method == "HEAD" { return .normal(HTTPResponse(status: resp.status, headers: resp.headers, body: Data())) }
                return .normal(resp)
            } catch {
                logger.error("[req:\(rid, privacy: .public)] /v1/models error: \(String(describing: error), privacy: .public)")
                AppLog.error("/v1/models failed: \(error.localizedDescription)", source: "http")
                let msg = ["error": ["message": error.localizedDescription]]
                let data = try? JSONSerialization.data(withJSONObject: msg, options: [])
                return .normal(HTTPResponse(status: 400, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data ?? Data()))
            }
        }

        // Debug: GET /debug/health -> simple health check
        if (request.method == "GET" || request.method == "HEAD") && path == "/debug/health" {
            let serverIsRunning = await self.isRunning
            let serverPort = await self.port
            let activeReqs = await self.getActiveRequestCount()
            let inferenceStats = await FoundationModelsService.shared.inferenceSemaphore.stats
            let metricsSnap = await ServerMetrics.shared.snapshot
            let obj: [String: Any] = [
                "status": "ok",
                "running": serverIsRunning,
                "port": serverPort,
                "active_requests": activeReqs,
                "inference": [
                    "running": inferenceStats.running,
                    "queued": inferenceStats.queued,
                    "max_concurrent": inferenceStats.maxConcurrent,
                    "total_completed": inferenceStats.totalCompleted,
                    "total_queued": inferenceStats.totalQueued,
                ],
                "metrics": [
                    "total_requests": metricsSnap.totalRequests,
                    "total_inference_requests": metricsSnap.totalInferenceRequests,
                    "total_tokens": metricsSnap.totalTokens,
                    "requests_last_5min": metricsSnap.requestsLast5Min,
                    "avg_ttft_seconds": metricsSnap.averageTTFT ?? -1,
                    "last_ttft_seconds": metricsSnap.lastTTFT ?? -1,
                ] as [String: Any]
            ]
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
            let resp = HTTPResponse(status: 200, headers: [
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": corsOrigin
            ], body: data)
            if request.method == "HEAD" { return .normal(HTTPResponse(status: resp.status, headers: resp.headers, body: Data())) }
            return .normal(resp)
        }

        // Debug: POST /debug/echo -> echoes method, path, headers, and body
        if request.method == "POST" && path == "/debug/echo" {
            var payload: [String: Any] = [:]
            payload["method"] = request.method
            payload["path"] = request.path
            payload["headers"] = request.headers
            if let bodyStr = String(data: request.bodyData, encoding: .utf8) {
                payload["bodyUtf8"] = bodyStr
            } else {
                payload["bodyBytes"] = request.bodyData.count
            }
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])) ?? Data()
            return .normal(HTTPResponse(status: 200, headers: [
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": corsOrigin
            ], body: data))
        }

        // Basic index for root, to satisfy HEAD/GET / pings from clients.
        if (request.method == "GET" || request.method == "HEAD") && path == "/" {
            let endpoints: [String] = [
                "/v1/models",
                "/v1/chat/completions",
                "/v1/completions",
                "/api/generate",
                "/api/tags",
                "/api/version",
                "/api/ps",
                "/api/chat",
                "/debug/health",
                "/debug/echo"
            ]
            let obj: [String: Any] = [
                "name": "afm-server Local API",
                "endpoints": endpoints
            ]
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])) ?? Data()
            let resp = HTTPResponse(status: 200, headers: [
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": corsOrigin
            ], body: data)
            if request.method == "HEAD" { return .normal(HTTPResponse(status: resp.status, headers: resp.headers, body: Data())) }
            return .normal(resp)
        }

        // Mirror GET /api/models (list)
        if (request.method == "GET" || request.method == "HEAD") && path == "/api/models" {
            do {
                let models = FoundationModelsService.shared.listModels()
                let data = try JSONEncoder().encode(models)
                let resp = HTTPResponse(status: 200, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data)
                if request.method == "HEAD" { return .normal(HTTPResponse(status: resp.status, headers: resp.headers, body: Data())) }
                return .normal(resp)
            } catch {
                logger.error("[req:\(rid, privacy: .public)] /api/models error: \(String(describing: error), privacy: .public)")
                let msg = ["error": ["message": error.localizedDescription]]
                let data = try? JSONSerialization.data(withJSONObject: msg, options: [])
                return .normal(HTTPResponse(status: 400, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data ?? Data()))
            }
        }

        // Ollama-compatible: GET /api/tags (list models)
        if (request.method == "GET" || request.method == "HEAD") && path == "/api/tags" {
            do {
                let tags = FoundationModelsService.shared.listOllamaTags()
                let data = try JSONEncoder().encode(tags)
                let resp = HTTPResponse(status: 200, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data)
                if request.method == "HEAD" { return .normal(HTTPResponse(status: resp.status, headers: resp.headers, body: Data())) }
                return .normal(resp)
            } catch {
                logger.error("[req:\(rid, privacy: .public)] /api/tags error: \(String(describing: error), privacy: .public)")
                let msg = ["error": ["message": error.localizedDescription]]
                let data = try? JSONSerialization.data(withJSONObject: msg, options: [])
                return .normal(HTTPResponse(status: 400, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data ?? Data()))
            }
        }

        // Ollama-compatible: GET /api/version
        if (request.method == "GET" || request.method == "HEAD") && path == "/api/version" {
            let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            let obj = ["version": bundleVersion]
            let data = (try? JSONSerialization.data(withJSONObject: obj, options: [])) ?? Data()
            let resp = HTTPResponse(status: 200, headers: [
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": corsOrigin
            ], body: data)
            if request.method == "HEAD" { return .normal(HTTPResponse(status: resp.status, headers: resp.headers, body: Data())) }
            return .normal(resp)
        }

        // Ollama-compatible: GET /api/ps (list running models) – we don't manage sessions, so return empty
        if (request.method == "GET" || request.method == "HEAD") && path == "/api/ps" {
            let data = Data("{\"models\": []}".utf8)
            let resp = HTTPResponse(status: 200, headers: [
                "Content-Type": "application/json",
                "Access-Control-Allow-Origin": corsOrigin
            ], body: data)
            if request.method == "HEAD" { return .normal(HTTPResponse(status: resp.status, headers: resp.headers, body: Data())) }
            return .normal(resp)
        }

        // Ollama-compatible: POST /api/chat
        if request.method == "POST" && path == "/api/chat" {
            do {
                let decoder = JSONDecoder()
                let req = try decoder.decode(FoundationModelsService.OllamaChatRequest.self, from: request.bodyData)
                if req.stream == true {
                    return .stream(HTTPStreamResponse.ndjson(origin: corsOrigin, handler: { emitter in
                        let respObj = try await FoundationModelsService.shared.handleOllamaChat(req)
                        logger.log("[req:\(rid, privacy: .public)] /api/chat streaming model=\(respObj.model, privacy: .public)")

                        for chunk in StreamChunker.chunk(text: respObj.message.content) {
                            let event: [String: Any] = [
                                "model": respObj.model,
                                "created_at": respObj.created_at,
                                "message": [
                                    "role": respObj.message.role,
                                    "content": chunk
                                ],
                                "done": false
                            ]
                            try await emitter.emitNDJSON(json: event)
                        }

                        let final: [String: Any] = [
                            "model": respObj.model,
                            "created_at": ISO8601DateFormatter().string(from: Date()),
                            "done": true
                        ]
                        try await emitter.emitNDJSON(json: final)
                    }))
                }
                let respObj = try await FoundationModelsService.shared.handleOllamaChat(req)
                let data = try JSONEncoder().encode(respObj)
                logger.log("[req:\(rid, privacy: .public)] /api/chat ok model=\(respObj.model, privacy: .public) msgLen=\(respObj.message.content.count)")
                return .normal(HTTPResponse(status: 200, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data))
            } catch {
                logger.error("[req:\(rid, privacy: .public)] /api/chat error: \(String(describing: error), privacy: .public) body=\(Self.truncateBodyForLog(request.bodyData), privacy: .public)")
                let msg = ["error": ["message": error.localizedDescription]]
                let data = try? JSONSerialization.data(withJSONObject: msg, options: [])
                return .normal(HTTPResponse(status: 400, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data ?? Data()))
            }
        }

        // Route GET /v1/models/{id}
        if (request.method == "GET" || request.method == "HEAD") && path.hasPrefix("/v1/models/") {
            let id = String(path.dropFirst("/v1/models/".count))
            if let model = FoundationModelsService.shared.getModel(id: id) {
                do {
                    let data = try JSONEncoder().encode(model)
                    let resp = HTTPResponse(status: 200, headers: [
                        "Content-Type": "application/json",
                        "Access-Control-Allow-Origin": corsOrigin
                    ], body: data)
                    if request.method == "HEAD" { return .normal(HTTPResponse(status: resp.status, headers: resp.headers, body: Data())) }
                    return .normal(resp)
                } catch {
                    logger.error("[req:\(rid, privacy: .public)] /v1/models/{id} encode error: \(String(describing: error), privacy: .public)")
                    let msg = ["error": ["message": error.localizedDescription]]
                    let data = try? JSONSerialization.data(withJSONObject: msg, options: [])
                    return .normal(HTTPResponse(status: 400, headers: [
                        "Content-Type": "application/json",
                        "Access-Control-Allow-Origin": corsOrigin
                    ], body: data ?? Data()))
                }
            } else {
                logger.error("[req:\(rid, privacy: .public)] /v1/models/{id} not found")
                let msg = [
                    "error": [
                        "message": "Model not found",
                        "type": "invalid_request_error"
                    ]
                ]
                let data = try? JSONSerialization.data(withJSONObject: msg, options: [])
                return .normal(HTTPResponse(status: 404, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data ?? Data()))
            }
        }

        // Mirror GET /api/models/{id}
        if (request.method == "GET" || request.method == "HEAD") && path.hasPrefix("/api/models/") {
            let id = String(path.dropFirst("/api/models/".count))
            if let model = FoundationModelsService.shared.getModel(id: id) {
                do {
                    let data = try JSONEncoder().encode(model)
                    let resp = HTTPResponse(status: 200, headers: [
                        "Content-Type": "application/json",
                        "Access-Control-Allow-Origin": corsOrigin
                    ], body: data)
                    if request.method == "HEAD" { return .normal(HTTPResponse(status: resp.status, headers: resp.headers, body: Data())) }
                    return .normal(resp)
                } catch {
                    logger.error("[req:\(rid, privacy: .public)] /api/models/{id} encode error: \(String(describing: error), privacy: .public)")
                    let msg = ["error": ["message": error.localizedDescription]]
                    let data = try? JSONSerialization.data(withJSONObject: msg, options: [])
                    return .normal(HTTPResponse(status: 400, headers: [
                        "Content-Type": "application/json",
                        "Access-Control-Allow-Origin": corsOrigin
                    ], body: data ?? Data()))
                }
            } else {
                logger.error("[req:\(rid, privacy: .public)] /api/models/{id} not found")
                let msg = [
                    "error": [
                        "message": "Model not found",
                        "type": "invalid_request_error"
                    ]
                ]
                let data = try? JSONSerialization.data(withJSONObject: msg, options: [])
                return .normal(HTTPResponse(status: 404, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data ?? Data()))
            }
        }

        // Route POST /v1/completions (text completions)
        if request.method == "POST" && path == "/v1/completions" {
            do {
                let decoder = JSONDecoder()
                let req = try decoder.decode(TextCompletionRequest.self, from: request.bodyData)
                if req.stream == true {
                    // Simulate streaming via SSE with small text chunks
                    return .stream(HTTPStreamResponse.sse(origin: corsOrigin, handler: { emitter in
                        let resp = try await FoundationModelsService.shared.handleCompletion(req)
                        let full = resp.choices.first?.text ?? ""
                        logger.log("[req:\(rid, privacy: .public)] /v1/completions streaming text len=\(full.count)")
                        for chunk in StreamChunker.chunk(text: full) {
                            let event: [String: Any] = [
                                "id": resp.id,
                                "object": "text_completion.chunk",
                                "created": resp.created,
                                "model": resp.model,
                                "choices": [["text": chunk, "index": 0, "finish_reason": NSNull()]]
                            ]
                            try await emitter.emitSSE(json: event)
                        }
                        // Final event
                        try await emitter.emitSSE(raw: "[DONE]")
                    }))
                } else {
                    let resp = try await FoundationModelsService.shared.handleCompletion(req)
                    let data = try JSONEncoder().encode(resp)
                    logger.log("[req:\(rid, privacy: .public)] /v1/completions ok textLen=\(resp.choices.first?.text.count ?? 0)")
                    return .normal(HTTPResponse(status: 200, headers: [
                        "Content-Type": "application/json",
                        "Access-Control-Allow-Origin": corsOrigin
                    ], body: data))
                }
            } catch {
                logger.error("[req:\(rid, privacy: .public)] /v1/completions error: \(String(describing: error), privacy: .public) body=\(Self.truncateBodyForLog(request.bodyData), privacy: .public)")
                let msg = ["error": ["message": error.localizedDescription]]
                let data = try? JSONSerialization.data(withJSONObject: msg, options: [])
                return .normal(HTTPResponse(status: 400, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data ?? Data()))
            }
        }

        // Mirror POST /api/generate to the same text completions behavior
        if request.method == "POST" && path == "/api/generate" {
            do {
                let decoder = JSONDecoder()
                let req = try decoder.decode(TextCompletionRequest.self, from: request.bodyData)
                if req.stream == true {
                    // Ollama style NDJSON streaming with "response" chunks
                    return .stream(HTTPStreamResponse.ndjson(origin: corsOrigin, handler: { emitter in
                        let resp = try await FoundationModelsService.shared.handleCompletion(req)
                        let full = resp.choices.first?.text ?? ""
                        logger.log("[req:\(rid, privacy: .public)] /api/generate streaming text len=\(full.count)")
                        for chunk in StreamChunker.chunk(text: full) {
                            let event: [String: Any] = [
                                "model": resp.model,
                                "created_at": ISO8601DateFormatter().string(from: Date()),
                                "response": chunk,
                                "done": false
                            ]
                            try await emitter.emitNDJSON(json: event)
                        }
                        let final: [String: Any] = [
                            "model": resp.model,
                            "created_at": ISO8601DateFormatter().string(from: Date()),
                            "done": true
                        ]
                        try await emitter.emitNDJSON(json: final)
                    }))
                } else {
                    let resp = try await FoundationModelsService.shared.handleCompletion(req)
                    let data = try JSONEncoder().encode(resp)
                    logger.log("[req:\(rid, privacy: .public)] /api/generate ok textLen=\(resp.choices.first?.text.count ?? 0)")
                    return .normal(HTTPResponse(status: 200, headers: [
                        "Content-Type": "application/json",
                        "Access-Control-Allow-Origin": corsOrigin
                    ], body: data))
                }
            } catch {
                logger.error("[req:\(rid, privacy: .public)] /api/generate error: \(String(describing: error), privacy: .public) body=\(Self.truncateBodyForLog(request.bodyData), privacy: .public)")
                let msg = ["error": ["message": error.localizedDescription]]
                let data = try? JSONSerialization.data(withJSONObject: msg, options: [])
                return .normal(HTTPResponse(status: 400, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data ?? Data()))
            }
        }

        // Route only POST /v1/chat/completions
        if request.method == "POST" && path == "/v1/chat/completions" {
            do {
                let decoder = JSONDecoder()
                let req = try decoder.decode(ChatCompletionRequest.self, from: request.bodyData)
                if req.stream == true {
                    return .stream(HTTPStreamResponse.sse(origin: corsOrigin, handler: { emitter in
                        let hasTools = !(req.tools?.isEmpty ?? true)
                        let useMulti = (!hasTools) && (req.multi_segment == true)

                        let streamId = "chatcmpl_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
                        let created = Int(Date().timeIntervalSince1970)
                        var resolvedSessionID: String? = nil
                        var finalFinishReason = "stop"

                        if hasTools {
                            // Tools path: delegate OpenAI-compatible tool_calls back to the client harness.
                            logger.log("[req:\(rid, privacy: .public)] /v1/chat/completions streaming mode=tools")
                            do {
                                let resp = try await FoundationModelsService.shared.handleChatCompletion(req)
                                let choice = resp.choices.first
                                finalFinishReason = choice?.finish_reason ?? "stop"
                                let toolCalls = choice?.message.tool_calls ?? []

                                if !toolCalls.isEmpty {
                                    let roleEvent: [String: Any] = [
                                        "id": streamId,
                                        "object": "chat.completion.chunk",
                                        "created": created,
                                        "model": req.model,
                                        "choices": [["index": 0, "delta": ["role": "assistant"]]]
                                    ]
                                    try? await emitter.emitSSE(json: roleEvent)

                                    let streamedToolCalls: [[String: Any]] = toolCalls.enumerated().map { index, call in
                                        [
                                            "index": index,
                                            "id": call.id,
                                            "type": call.type,
                                            "function": [
                                                "name": call.function.name,
                                                "arguments": call.function.arguments
                                            ]
                                        ]
                                    }
                                    let event: [String: Any] = [
                                        "id": streamId,
                                        "object": "chat.completion.chunk",
                                        "created": created,
                                        "model": req.model,
                                        "choices": [["index": 0, "delta": ["tool_calls": streamedToolCalls]]]
                                    ]
                                    try? await emitter.emitSSE(json: event)
                                } else {
                                    let full = choice?.message.content ?? ""
                                    for chunk in StreamChunker.chunk(text: full) {
                                        let event: [String: Any] = [
                                            "id": streamId,
                                            "object": "chat.completion.chunk",
                                            "created": created,
                                            "model": req.model,
                                            "choices": [["index": 0, "delta": ["content": chunk]]]
                                        ]
                                        try? await emitter.emitSSE(json: event)
                                    }
                                }
                            } catch {
                                logger.error("[req:\(rid, privacy: .public)] tools streaming error: \(String(describing: error), privacy: .public)")
                                let fallback = "(Local fallback) Unable to generate a response. This may be due to safety guardrails or an unavailable model."
                                let event: [String: Any] = [
                                    "id": streamId,
                                    "object": "chat.completion.chunk",
                                    "created": created,
                                    "model": req.model,
                                    "choices": [["index": 0, "delta": ["content": fallback]]]
                                ]
                                try? await emitter.emitSSE(json: event)
                            }
                        } else if useMulti {
                            // Legacy multi-segment mode (opt-in only via multi_segment=true)
                            logger.log("[req:\(rid, privacy: .public)] /v1/chat/completions streaming mode=multi segmentChars=1400 maxSegments=6")
                            do {
                                try await FoundationModelsService.shared.generateChatSegments(messages: req.messages, model: req.model, temperature: req.temperature, segmentChars: 1400, maxSegments: 6) { segment in
                                    let event: [String: Any] = [
                                        "id": streamId,
                                        "object": "chat.completion.chunk",
                                        "created": created,
                                        "model": req.model,
                                        "choices": [["index": 0, "delta": ["content": segment]]]
                                    ]
                                    try? await emitter.emitSSE(json: event)
                                }
                            } catch {
                                logger.error("[req:\(rid, privacy: .public)] multi-segment generation failed: \(String(describing: error), privacy: .public)")
                                let fallback = "(Local fallback) Unable to continue the streamed response. Please try rephrasing."
                                let event: [String: Any] = [
                                    "id": streamId,
                                    "object": "chat.completion.chunk",
                                    "created": created,
                                    "model": req.model,
                                    "choices": [["index": 0, "delta": ["content": fallback]]]
                                ]
                                try? await emitter.emitSSE(json: event)
                            }
                        } else {
                            // DEFAULT: True token-by-token streaming via Foundation Models streamResponse
                            logger.log("[req:\(rid, privacy: .public)] /v1/chat/completions streaming mode=token-stream sessionID=\(req.session_id ?? "new", privacy: .public)")
                            do {
                                resolvedSessionID = try await FoundationModelsService.shared.streamChatCompletion(
                                    messages: req.messages,
                                    model: req.model,
                                    temperature: req.temperature,
                                    sessionID: req.session_id
                                ) { delta in
                                    let event: [String: Any] = [
                                        "id": streamId,
                                        "object": "chat.completion.chunk",
                                        "created": created,
                                        "model": req.model,
                                        "choices": [["index": 0, "delta": ["content": delta]]]
                                    ]
                                    try? await emitter.emitSSE(json: event)
                                }
                            } catch {
                                logger.error("[req:\(rid, privacy: .public)] token streaming failed: \(String(describing: error), privacy: .public)")
                                let fallback = "(Local fallback) Unable to stream a response. Please try rephrasing."
                                let event: [String: Any] = [
                                    "id": streamId,
                                    "object": "chat.completion.chunk",
                                    "created": created,
                                    "model": req.model,
                                    "choices": [["index": 0, "delta": ["content": fallback]]]
                                ]
                                try? await emitter.emitSSE(json: event)
                            }
                        }

                        // Terminal chunk + [DONE] for all paths
                        var finalEvent: [String: Any] = [
                            "id": streamId,
                            "object": "chat.completion.chunk",
                            "created": created,
                            "model": req.model,
                            "choices": [["index": 0, "delta": [:], "finish_reason": finalFinishReason]]
                        ]
                        if let sid = resolvedSessionID {
                            finalEvent["session_id"] = sid
                        }
                        try? await emitter.emitSSE(json: finalEvent)
                        try? await emitter.emitSSE(raw: "[DONE]")
                    }))
                } else {
                    let resp = try await FoundationModelsService.shared.handleChatCompletion(req)
                    let data = try JSONEncoder().encode(resp)
                    logger.log("[req:\(rid, privacy: .public)] /v1/chat/completions ok msgLen=\(resp.choices.first?.message.content.count ?? 0)")
                    return .normal(HTTPResponse(status: 200, headers: [
                        "Content-Type": "application/json",
                        "Access-Control-Allow-Origin": corsOrigin
                    ], body: data))
                }
            } catch {
                logger.error("[req:\(rid, privacy: .public)] /v1/chat/completions error: \(String(describing: error), privacy: .public) body=\(Self.truncateBodyForLog(request.bodyData), privacy: .public)")
                AppLog.error("/v1/chat/completions failed: \(error.localizedDescription)", source: "http")
                let msg = ["error": ["message": error.localizedDescription]]
                let data = try? JSONSerialization.data(withJSONObject: msg, options: [])
                return .normal(HTTPResponse(status: 400, headers: [
                    "Content-Type": "application/json",
                    "Access-Control-Allow-Origin": corsOrigin
                ], body: data ?? Data()))
            }
        }
        // Not Found
        logger.error("[req:\(rid, privacy: .public)] 404 Not Found \(path, privacy: .public)")
        AppLog.warning("404 Not Found: \(path)", source: "http")
        let body = Data("Not Found".utf8)
        return .normal(HTTPResponse(status: 404, headers: [
            "Content-Type": "text/plain",
            "Access-Control-Allow-Origin": corsOrigin
        ], body: body))
    }

    // MARK: - Actor-isolated helpers

    private func handleListenerState(_ state: NWListener.State, currentPort: UInt16) async {
        let isStalePortEvent = currentPort != port
        switch state {
        case .ready:
            guard !isStalePortEvent else {
                logger.log("Ignoring stale ready event for port \(currentPort); active port is \(self.port)")
                return
            }
            logger.log("HTTP server listening on localhost:\(currentPort) (loopback only)")
            AppLog.info("HTTP server listening on localhost:\(currentPort)", source: "server")
            isRunning = true
            lastError = nil
        case .failed(let error):
            guard !isStalePortEvent else {
                logger.log("Ignoring stale failure event for port \(currentPort); active port is \(self.port)")
                return
            }
            let isAddressInUse: Bool
            if let posixError = error as? NWError,
               case .posix(let code) = posixError,
               code == .EADDRINUSE {
                isAddressInUse = true
            } else {
                isAddressInUse = false
            }
            
            logger.error("Listener failed on port \(currentPort): \(String(describing: error))")
            AppLog.error("Listener failed on port \(currentPort): \(error.localizedDescription)", source: "server")
            listener?.cancel()
            listener = nil
            isRunning = false
            
            // If address is in use, try the next port
            if isAddressInUse {
                currentPortIndex += 1
                if currentPortIndex < portsToTry.count {
                    logger.log("Port \(currentPort) in use, trying next port...")
                    AppLog.warning("Port \(currentPort) in use; trying next port", source: "server")
                    await tryStartOnNextPort()
                } else {
                    lastError = "All ports in use. Tried: \(portsToTry.map(String.init).joined(separator: ", "))"
                    logger.error("\(self.lastError ?? "")")
                    AppLog.error(lastError ?? "All ports in use", source: "server")
                }
            } else {
                lastError = "Server failed: \(error.localizedDescription)"
                AppLog.error(lastError ?? "Server failed", source: "server")
            }
        case .cancelled:
            guard !isStalePortEvent else {
                logger.log("Ignoring stale cancel event for port \(currentPort); active port is \(self.port)")
                return
            }
            logger.log("Listener cancelled")
            AppLog.info("Listener cancelled", source: "server")
            isRunning = false
        default:
            break
        }
    }

    private func accept(_ newConn: NWConnection) async {
        let wrapper = ConnectionWrapper(connection: newConn, server: self)
        connections.insert(wrapper)
        wrapper.start()
    }

    nonisolated fileprivate func removeConnection(_ wrapper: ConnectionWrapper) {
        Task { await self._removeConnection(wrapper) }
    }

    private func _removeConnection(_ wrapper: ConnectionWrapper) {
        connections.remove(wrapper)
    }

    // Public actor APIs for cross-actor access
    func setPort(_ newPort: UInt16) {
        self.port = newPort
    }

    func getIsRunning() -> Bool {
        isRunning
    }

    func getPort() -> UInt16 {
        port
    }

    func getLastError() -> String? {
        lastError
    }

    func clearError() {
        lastError = nil
    }
}

// MARK: - Logging helpers

extension LocalHTTPServer {
    /// Whether to log full request bodies without truncation.
    /// Enabled if either:
    /// - UserDefaults: `debugFullRequestLog` or `debugLogging` is true, or
    /// - Env var `PI_DEBUG_FULL_LOG=1` is present.
    nonisolated private static func debugFullRequestLogEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "debugFullRequestLog") { return true }
        if defaults.bool(forKey: "debugLogging") { return true }
        if ProcessInfo.processInfo.environment["PI_DEBUG_FULL_LOG"] == "1" { return true }
        return false
    }

    nonisolated static func truncateBodyForLog(_ data: Data, limit: Int = 8192) -> String {
        guard let s = String(data: data, encoding: .utf8) else { return "<non-utf8 body \(data.count) bytes>" }
        let redacted = redactAuthorization(in: s)
        if debugFullRequestLogEnabled() { return redacted.replacingOccurrences(of: "\n", with: "\\n") }
        if redacted.count <= limit { return redacted.replacingOccurrences(of: "\n", with: "\\n") }
        let idx = redacted.index(redacted.startIndex, offsetBy: limit)
        return redacted[redacted.startIndex..<idx].replacingOccurrences(of: "\n", with: "\\n") + "… (truncated)"
    }

    nonisolated private static func redactAuthorization(in s: String) -> String {
        if s.lowercased().contains("authorization") {
            // Very simple masking for tokens in body if present
            return s.replacingOccurrences(of: "Authorization", with: "Authorization(REDACTED)")
        }
        return s
    }
}

// MARK: - Minimal HTTP over TCP

nonisolated private final class ConnectionWrapper: @unchecked Sendable, Hashable {
    static func == (lhs: ConnectionWrapper, rhs: ConnectionWrapper) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    private let logger = Logger(subsystem: "online.techopolis.afm-server", category: "Connection")
    private let connection: NWConnection
    private unowned let server: LocalHTTPServer
    private var buffer = Data()
    private var connectionEnded = false
    private var didCancel = false

    init(connection: NWConnection, server: LocalHTTPServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let strongSelf = self else { return }
            switch state {
            case .ready:
                strongSelf.receive()
            case .failed, .cancelled:
                strongSelf.cancel()
            default: break
            }
        }
        connection.start(queue: DispatchQueue.global())
    }

    func cancel() {
        guard !didCancel else { return }
        didCancel = true
        connection.cancel()
        server.removeConnection(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let strongSelf = self else { return }
            if let data, !data.isEmpty { strongSelf.buffer.append(data) }
            strongSelf.connectionEnded = strongSelf.connectionEnded || isComplete || (error != nil)

            if let request = strongSelf.tryParseRequest() {
                Task {
                    let response = await strongSelf.server.handleRequest(request)
                    strongSelf.sendServerResponse(response)
                }
                return
            }
            if strongSelf.connectionEnded {
                // If connection ended but we couldn't parse a full request, return Bad Request
                strongSelf.logger.error("Failed to parse full HTTP request before connection ended")
                strongSelf.send(HTTPResponse(status: 400, headers: ["Content-Type": "text/plain"], body: Data("Bad Request".utf8)))
                return
            }
            strongSelf.receive()
        }
    }

    private func send(_ response: HTTPResponse) {
        let data = response.serialize()
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.cancel()
        })
    }

    private func sendServerResponse(_ response: ServerResponse) {
        switch response {
        case .normal(let resp):
            send(resp)
        case .stream(let s):
            sendStream(s)
        }
    }

    private func sendStream(_ s: HTTPStreamResponse) {
        // Prepare headers for chunked transfer
        var lines: [String] = []
        lines.append("HTTP/1.1 200 OK")
        var headers = s.headers
        headers["Transfer-Encoding"] = "chunked"
        headers["Connection"] = "close"
        for (k, v) in headers { lines.append("\(k): \(v)") }
        lines.append("")
        let head = (lines.joined(separator: "\r\n") + "\r\n").data(using: .utf8) ?? Data()
        connection.send(content: head, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            Task {
                let sender = StreamSender(connection: self.connection)
                await s.run { chunk in
                    await sender.sendChunked(chunk)
                }
                await sender.finish()
            }
        })
    }

    // Actor that owns writes to the NWConnection during a streaming response
    // Each send awaits the completion handler to ensure data flushes to the network
    // before the next chunk is sent — critical for real-time SSE streaming.
    private actor StreamSender {
        private let connection: NWConnection

        init(connection: NWConnection) {
            self.connection = connection
        }

        func sendChunked(_ data: Data) async {
            let prefix = String(format: "%@\r\n", String(data.count, radix: 16)).data(using: .utf8) ?? Data()
            var out = Data()
            out.append(prefix)
            out.append(data)
            out.append(Data("\r\n".utf8))
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(content: out, completion: .contentProcessed({ _ in
                    continuation.resume()
                }))
            }
        }

        func finish() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed({ _ in
                    self.connection.cancel()
                    continuation.resume()
                }))
            }
        }
    }

    // MARK: - Buffered HTTP parsing

    private func tryParseRequest() -> HTTPRequest? {
        // Look for end of headers \r\n\r\n
        guard let headerRange = buffer.range(of: Data([13,10,13,10])) else { // \r\n\r\n
            return nil
        }
        let headData = buffer.subdata(in: 0..<headerRange.lowerBound)
        guard let headText = String(data: headData, encoding: .utf8) else { return nil }
        let headLines = headText.components(separatedBy: "\r\n")
        guard let requestLine = headLines.first else { return nil }
        let comps = requestLine.split(separator: " ")
        guard comps.count >= 2 else { return nil }
        let method = String(comps[0])
        let path = String(comps[1])
        var headers: [String: String] = [:]
        for line in headLines.dropFirst() {
            if let sep = line.firstIndex(of: ":") {
                let key = String(line[..<sep]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        let bodyStart = headerRange.upperBound
        let contentLength = (headers["content-length"] ?? headers["Content-Length"]).flatMap { Int($0) }
        let availableBodyBytes = buffer.count - bodyStart
        let expectedBodyBytes = contentLength ?? availableBodyBytes
        guard availableBodyBytes >= expectedBodyBytes else {
            // Need more data
            return nil
        }
        let bodyData = buffer.subdata(in: bodyStart..<(bodyStart + expectedBodyBytes))
        // Consume used bytes from buffer
        if bodyStart + expectedBodyBytes <= buffer.count {
            buffer.removeSubrange(0..<(bodyStart + expectedBodyBytes))
        }
        return HTTPRequest(method: method, path: path, headers: headers, bodyData: bodyData)
    }
}

// MARK: - HTTP Types

nonisolated struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let bodyData: Data
}

nonisolated struct HTTPResponse: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    func serialize() -> Data {
        var lines: [String] = []
        lines.append("HTTP/1.1 \(status) \(statusText(status))")
        lines.append("Content-Length: \(body.count)")
        for (k, v) in headers { lines.append("\(k): \(v)") }
        lines.append("")
        let head = lines.joined(separator: "\r\n") + "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    private func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        default: return "OK"
        }
    }
}

// MARK: - Streaming Support

nonisolated enum ServerResponse: Sendable {
    case normal(HTTPResponse)
    case stream(HTTPStreamResponse)
}

nonisolated final class HTTPStreamResponse: @unchecked Sendable {
    typealias Emitter = StreamingEmitter

    let headers: [String: String]
    private let runner: (Emitter) async -> Void

    init(headers: [String: String], runner: @escaping (Emitter) async -> Void) {
        self.headers = headers
        self.runner = runner
    }

    static func sse(origin: String, handler: @escaping (Emitter) async throws -> Void) -> HTTPStreamResponse {
        return HTTPStreamResponse(headers: [
            "Content-Type": "text/event-stream",
            "Cache-Control": "no-cache",
            "Access-Control-Allow-Origin": origin
        ]) { emitter in
            try? await handler(emitter)
        }
    }

    static func ndjson(origin: String, handler: @escaping (Emitter) async throws -> Void) -> HTTPStreamResponse {
        return HTTPStreamResponse(headers: [
            "Content-Type": "application/x-ndjson",
            "Cache-Control": "no-cache",
            "Access-Control-Allow-Origin": origin
        ]) { emitter in
            try? await handler(emitter)
        }
    }

    func run(emit: @escaping @Sendable (Data) async -> Void) async {
        let emitter = StreamingEmitter(emit: emit)
        await runner(emitter)
    }

    struct StreamingEmitter {
        let emit: @Sendable (Data) async -> Void

        func emitSSE(raw: String) async throws {
            let line = "data: \(raw)\n\n"
            guard let data = line.data(using: .utf8) else { return }
            await emit(data)
        }

        func emitSSE(json: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: json, options: [])
            if let str = String(data: data, encoding: .utf8) {
                try await emitSSE(raw: str)
            }
        }

        func emitNDJSON(json: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: json, options: [])
            var nd = data
            nd.append(0x0A) // newline
            await emit(nd)
        }
    }
}

nonisolated enum StreamChunker: Sendable {
    static func chunk(text: String, size: Int = 64) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[idx..<end]))
            idx = end
        }
        return chunks
    }
}

nonisolated enum HTTPRequestParser: Sendable {
    static func parse(data: Data) -> HTTPRequest? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: "\r\n\r\n")
        guard parts.count >= 1 else { return nil }
        let head = parts[0]
        let bodyString = parts.dropFirst().joined(separator: "\r\n\r\n")
        let headLines = head.components(separatedBy: "\r\n")
        guard let requestLine = headLines.first else { return nil }
        let comps = requestLine.split(separator: " ")
        guard comps.count >= 2 else { return nil }
        let method = String(comps[0])
        let path = String(comps[1])
        var headers: [String: String] = [:]
        for line in headLines.dropFirst() {
            if let sep = line.firstIndex(of: ":") {
                let rawKey = String(line[..<sep]).trimmingCharacters(in: .whitespaces)
                let key = rawKey.lowercased()
                let value = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }
        let bodyData = Data(bodyString.utf8)
        return HTTPRequest(method: method, path: path, headers: headers, bodyData: bodyData)
    }
}
