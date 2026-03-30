import Foundation

// Define the Model struct that conforms to ModelProtocol
public struct Model: ModelProtocol, Sendable {
    public let name: String
    public let owner: String
    let size: Int64
    let modified_at: String
}

@MainActor
public final class OllamaService: LLMService, @unchecked Sendable {
    // MARK: - Singleton
    public static let shared = OllamaService()
    private let settings = Settings.shared
    private let logger = LoggerService.shared

    init() {
    }

    public struct PullProgress {
        public let status: String
        public let digest: String?
        public let total: Int64
        public let completed: Int64
    }

    // Base URL computed property
    private var baseUrl: String {
        let url = settings.llmService.url
        return url.hasSuffix("/") ? url : url + "/"
    }

    private func makeUrl(_ path: String) -> URL? {
        URL(string: "\(baseUrl)\(path)")
    }

    private func createSession(timeout: TimeInterval = 0) -> URLSession {
        let configuration = URLSessionConfiguration.default
        var userTimeout = Settings.shared.llmService.timeout
        if timeout > userTimeout {
            userTimeout = timeout
        }

        configuration.timeoutIntervalForRequest = userTimeout  // Timeout for each request
        configuration.timeoutIntervalForResource = userTimeout * 10  // Total timeout for the resource
        return URLSession(configuration: configuration)
    }

    // Check if Ollama is available
    public func checkAvailability() async -> Bool {
        guard let url = makeUrl("api/tags") else {
            logger.log("Invalid Ollama URL configuration", level: .error)
            return false
        }

        do {
            let session = createSession()
            let (_, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return httpResponse.statusCode == 200
        } catch {
            logger.log("Ollama health check failed: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    // Generate completion using Ollama
    public func generateCompletion(prompt: String, model: String = "llama2") async throws -> String
    {
        guard let url = makeUrl("api/generate") else {
            throw NSError(
                domain: "OllamaService", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama URL configuration"])
        }

        let parameters: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "options": [
                "temperature": settings.llmService.temperature,
                "top_p": settings.llmService.topP,
            ],
            "think": false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)

        do {
            let session = createSession()
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "OllamaService",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
            }

            if httpResponse.statusCode != 200 {
                // Try to parse error message from response data
                let errorMessage: String
                if let errorJson = try? JSONSerialization.jsonObject(with: data, options: [])
                    as? [String: Any],
                    let error = errorJson["error"] as? String
                {
                    errorMessage = error
                } else if let errorText = String(data: data, encoding: .utf8) {
                    errorMessage = errorText
                } else {
                    errorMessage = "Status code: \(httpResponse.statusCode)"
                }

                logger.log("Ollama generation failed: \(errorMessage)", level: .error)
                throw NSError(
                    domain: "OllamaService",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Chat request failed: \(errorMessage)"])
            }

            if let json = try JSONSerialization.jsonObject(with: data, options: [])
                as? [String: Any],
                let response = json["response"] as? String
            {
                return response
            } else {
                throw NSError(
                    domain: "OllamaService", code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
            }
        } catch {
            logger.log("Ollama generation failed: \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    public nonisolated func chatStream(
        messages: [ChatMessage], model: String = "llama3.2",
        formatter: ChatMessage.OutputFormatter? = nil
    )
        -> AsyncThrowingStream<ChatMessage, Error>
    {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                guard let url = makeUrl("api/chat") else {
                    continuation.finish(
                        throwing: NSError(
                            domain: "OllamaService",
                            code: -1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Invalid Ollama URL configuration"
                            ]))
                    return
                }

                do {
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    var parameters: [String: Any] = [
                        "model": model,
                        "messages": messages.map { message in
                            [
                                "role": message.role.rawValue,
                                "content": message.content,
                                "images": message.images,
                                "tool_calls": message.toolCalls?.map { toolCall in
                                    [
                                        "function": [
                                            "name": toolCall.name,
                                            "arguments": toolCall.arguments,
                                        ]
                                    ]
                                },
                            ]
                        },
                        "stream": true,
                        "options": [
                            "temperature": settings.llmService.temperature,
                            "top_p": settings.llmService.topP,
                            "num_ctx": settings.llmService.numCtx,
                        ],
                    ]
                    if let theFormatter = formatter {
                        parameters["formatter"] = theFormatter.asDict
                    }

                    request.httpBody = try JSONSerialization.data(withJSONObject: parameters)
                    let session = createSession()
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NSError(
                            domain: "OllamaService",
                            code: -2,
                            userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
                    }

                    if httpResponse.statusCode != 200 {
                        // Try to parse error message from response data
                        let errorMessage: String

                        // Collect bytes into Data
                        var errorData = Data()
                        for try await byte in bytes {
                            errorData.append(byte)
                        }

                        if let errorJson = try? JSONSerialization.jsonObject(
                            with: errorData, options: []) as? [String: Any],
                            let error = errorJson["error"] as? String
                        {
                            errorMessage = error
                        } else if let errorText = String(data: errorData, encoding: .utf8) {
                            errorMessage = errorText
                        } else {
                            errorMessage = "Status code: \(httpResponse.statusCode)"
                        }

                        logger.log("Ollama chat stream failed: \(errorMessage)", level: .error)
                        throw NSError(
                            domain: "OllamaService",
                            code: httpResponse.statusCode,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Chat request failed: \(errorMessage)"
                            ])
                    }

                    // Process the stream line by line
                    var buffer = Data()
                    for try await byte in bytes {
                        buffer.append(byte)

                        // Check if we have a complete line
                        if byte == UInt8(ascii: "\n") {
                            if let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(
                                in: .whitespacesAndNewlines),
                                !line.isEmpty
                            {
                                if let chatMessage = try parseStreamResponse(data: buffer) {
                                    continuation.yield(chatMessage)
                                }
                            }
                            buffer.removeAll()
                        }
                    }

                    // Handle any remaining data
                    if !buffer.isEmpty,
                        let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(
                            in: .whitespacesAndNewlines),
                        !line.isEmpty
                    {
                        if let chatMessage = try parseStreamResponse(data: buffer) {
                            continuation.yield(chatMessage)
                        }
                    }

                    continuation.finish()
                } catch {
                    logger.log(
                        "Ollama chat stream failed: \(error.localizedDescription)", level: .error)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public nonisolated func chat(
        messages: [ChatMessage], model: String = "llama3.2", tools: [ChatMessage.Tool]? = nil,
        formatter: ChatMessage.OutputFormatter? = nil
    )
        async throws
        -> ChatMessage
    {
        return try await Task { @MainActor in
            guard let url = makeUrl("api/chat") else {
                throw NSError(
                    domain: "OllamaService",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama URL configuration"])
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let toolsJson: [[String: Any]] =
                if let tools = tools {
                    LLMServiceFactory.toolsToDict(tools)
                } else {
                    []
                }

            let parameters: [String: Any] = [
                "model": model,
                "messages": messages.map { message in
                    [
                        "role": message.role.rawValue,
                        "content": message.content,
                        "images": message.images,
                        "tool_calls": message.toolCalls?.map { toolCall in
                            [
                                "function": [
                                    "name": toolCall.name,
                                    "arguments": toolCall.arguments,
                                ]
                            ]
                        },
                    ]
                },
                "stream": false,
                "tools": toolsJson,
                "options": [
                    "temperature": settings.llmService.temperature,
                    "top_p": settings.llmService.topP,
                    "num_ctx": settings.llmService.numCtx,
                ],
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: parameters)

            let session = createSession()
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                //close session
                session.finishTasksAndInvalidate()
                throw NSError(
                    domain: "OllamaService",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
            }

            if httpResponse.statusCode != 200 {
                //close session
                session.finishTasksAndInvalidate()
                // Try to parse error message from response data
                let errorMessage: String
                if let errorJson = try? JSONSerialization.jsonObject(with: data, options: [])
                    as? [String: Any],
                    let error = errorJson["error"] as? String
                {
                    errorMessage = error
                } else if let errorText = String(data: data, encoding: .utf8) {
                    errorMessage = errorText
                } else {
                    errorMessage = "Status code: \(httpResponse.statusCode)"
                }

                logger.log("Ollama chat failed: \(errorMessage)", level: .error)
                throw NSError(
                    domain: "OllamaService",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Chat request failed: \(errorMessage)"])
            }

            guard let chatMessage = try? parseStreamResponse(data: data) else {
                throw NSError(
                    domain: "OllamaService",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
            }

            //close session
            session.finishTasksAndInvalidate()

            return chatMessage
        }.value
    }

    public func parseStreamResponse(data: Data) throws -> ChatMessage? {
        if let json = try? JSONSerialization.jsonObject(with: data, options: [])
            as? [String: Any]
        {
            let message = json["message"] as? [String: Any]

            var toolCalls: [ChatMessage.ToolCall]?
            if let toolCallsJson = message?["tool_calls"] as? [[String: Any]] {
                toolCalls = toolCallsJson.compactMap { toolCallJson in
                    guard let functionJson = toolCallJson["function"] as? [String: Any] else {
                        return nil
                    }
                    guard let name = functionJson["name"] as? String,
                        let arguments = functionJson["arguments"] as? [String: String]
                    else { return nil }
                    return ChatMessage.ToolCall(name: name, arguments: arguments)
                }
            }

            let content = message?["content"] as? String ?? ""
            let doneReason = json["done_reason"] as? String
            let done = json["done"] as? Bool
            let totalDuration = json["total_duration"] as? Int64
            let loadDuration = json["load_duration"] as? Int64
            let promptEvalCount = json["prompt_eval_count"] as? Int
            let promptEvalDuration = json["prompt_eval_duration"] as? Int64
            let evalCount = json["eval_count"] as? Int
            let evalDuration = json["eval_duration"] as? Int64
            let model = json["model"] as? String
            return ChatMessage(
                role: .assistant, content: content, toolCalls: toolCalls, doneReason: doneReason,
                done: done,
                totalDuration: totalDuration, loadDuration: loadDuration,
                promptEvalCount: promptEvalCount,
                promptEvalDuration: promptEvalDuration, evalCount: evalCount,
                evalDuration: evalDuration,
                model: model)
        }
        return nil
    }

    public nonisolated func listModels() async throws -> [any ModelProtocol] {
        let models = try await Task { @MainActor in
            guard let url = makeUrl("api/tags") else {
                throw NSError(
                    domain: "OllamaService", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama URL configuration"])
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"

            do {
                let session = createSession()
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(
                        domain: "OllamaService",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
                }

                if httpResponse.statusCode != 200 {
                    // Try to parse error message from response data
                    let errorMessage: String
                    if let errorJson = try? JSONSerialization.jsonObject(with: data, options: [])
                        as? [String: Any],
                        let error = errorJson["error"] as? String
                    {
                        errorMessage = error
                    } else if let errorText = String(data: data, encoding: .utf8) {
                        errorMessage = errorText
                    } else {
                        errorMessage = "Status code: \(httpResponse.statusCode)"
                    }

                    logger.log("Ollama list models failed: \(errorMessage)", level: .error)
                    throw NSError(
                        domain: "OllamaService",
                        code: httpResponse.statusCode,
                        userInfo: [
                            NSLocalizedDescriptionKey: "List models request failed: \(errorMessage)"
                        ])
                }

                if let json = try JSONSerialization.jsonObject(with: data, options: [])
                    as? [String: Any],
                    let models = json["models"] as? [[String: Any]]
                {
                    return try models.map { modelDict in
                        guard let name = modelDict["name"] as? String,
                            let size = modelDict["size"] as? Int64,
                            let modified_at = modelDict["modified_at"] as? String
                        else {
                            throw NSError(
                                domain: "OllamaService", code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "Invalid model data format"])
                        }
                        return Model(name: name, owner: "", size: size, modified_at: modified_at)
                    }
                } else {
                    throw NSError(
                        domain: "OllamaService", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
                }
            } catch {
                logger.log(
                    "Failed to list Ollama models: \(error.localizedDescription)", level: .error)
                throw error
            }
        }.value

        return models
    }

    public func pullModel(name: String, progressHandler: @escaping (PullProgress) -> Void)
        async throws
    {
        guard let url = makeUrl("api/pull") else {
            throw NSError(
                domain: "OllamaService", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama URL configuration"])
        }

        let parameters: [String: Any] = [
            "name": name,
            "stream": true,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)

        let session = createSession(timeout: 3600 * 24 * 7)
        let (bytes, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OllamaService",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }

        if httpResponse.statusCode != 200 {
            // Try to parse error message from response data
            let errorMessage: String

            // Collect bytes into Data
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }

            if let errorJson = try? JSONSerialization.jsonObject(with: errorData, options: [])
                as? [String: Any],
                let error = errorJson["error"] as? String
            {
                errorMessage = error
            } else if let errorText = String(data: errorData, encoding: .utf8) {
                errorMessage = errorText
            } else {
                errorMessage = "Status code: \(httpResponse.statusCode)"
            }

            logger.log("Ollama pull model failed: \(errorMessage)", level: .error)
            throw NSError(
                domain: "OllamaService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Pull model request failed: \(errorMessage)"])
        }

        var buffer = ""
        for try await byte in bytes {
            if let char = String(bytes: [byte], encoding: .utf8) {
                buffer += char
                if char == "\n" {
                    if let data = buffer.data(using: .utf8),
                        let json = try? JSONSerialization.jsonObject(with: data, options: [])
                            as? [String: Any]
                    {

                        let status = json["status"] as? String ?? ""
                        let digest = json["digest"] as? String
                        let total = json["total"] as? Int64 ?? 0
                        let completed = json["completed"] as? Int64 ?? 0

                        let progress = PullProgress(
                            status: status,
                            digest: digest,
                            total: total,
                            completed: completed
                        )

                        progressHandler(progress)
                    }
                    buffer = ""
                }
            }
        }

        logger.log("Successfully pulled model: \(name)", level: .info)
    }
}
