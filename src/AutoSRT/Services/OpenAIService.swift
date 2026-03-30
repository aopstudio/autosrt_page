import Foundation

@MainActor
public final class OpenaiService: LLMService, @unchecked Sendable {
    // MARK: - Singleton
    public static let shared = OpenaiService()
    private let settings = Settings.shared
    private let logger = LoggerService.shared

    init() {}

    // Base URL computed property
    private var baseUrl: String {
        var url = settings.llmService.url
        // Remove trailing /v1 if it exists
        if url.hasSuffix("/v1") {
            url = String(url.dropLast(3))
        }
        // Ensure URL ends with a single slash
        return url.hasSuffix("/") ? url : url + "/"
    }

    private func makeUrl(_ path: String) -> URL? {
        URL(string: "\(baseUrl)\(path)")
    }

    private func createSession(timeout: Double = 0.0) -> URLSession {
        let configuration = URLSessionConfiguration.default
        var userTimeout = Settings.shared.llmService.timeout
        if timeout > userTimeout {
            userTimeout = timeout
        }

        configuration.timeoutIntervalForRequest = userTimeout  // Timeout for each request
        configuration.timeoutIntervalForResource = userTimeout * 10  // Total timeout for the resource
        return URLSession(configuration: configuration)
    }

    // Check if Openai is available
    public func checkAvailability() async -> Bool {
        guard let url = makeUrl("models") else {
            logger.log("Invalid Openai URL configuration", level: .error)
            return false
        }

        let session = createSession()

        var request = URLRequest(url: url)
        request.setValue(
            "Bearer \(settings.llmService.apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return false
            }
            return httpResponse.statusCode == 200
        } catch {
            logger.log("Openai health check failed: \(error.localizedDescription)", level: .error)
            return false
        }
    }

    // Generate completion using Openai
    public func generateCompletion(prompt: String, model: String = "llama2") async throws -> String
    {
        guard let url = makeUrl("v1/chat/completions") else {
            throw NSError(
                domain: "OpenaiService", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Openai URL configuration"])
        }

        let parameters: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "temperature": settings.llmService.temperature,
            "top_p": settings.llmService.topP,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(settings.llmService.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: parameters)

        let session = createSession()
        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "OpenaiService",
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

                logger.log("Openai generation failed: \(errorMessage)", level: .error)
                throw NSError(
                    domain: "OpenaiService",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Chat request failed: \(errorMessage)"])
            }

            guard
                let json = try? JSONSerialization.jsonObject(with: data, options: [])
                    as? [String: Any],
                let choices = json["choices"] as? [[String: Any]],
                let firstChoice = choices.first,
                let message = firstChoice["message"] as? [String: Any],
                let content = message["content"] as? String
            else {
                throw NSError(
                    domain: "OpenaiService",
                    code: -3,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid response json format"])
            }

            return content
        } catch {
            logger.log("Openai generation failed: \(error.localizedDescription)", level: .error)
            throw error
        }
    }

    // MARK: - Chat API

    public nonisolated func chatStream(
        messages: [ChatMessage], model: String, formatter: ChatMessage.OutputFormatter?
    ) -> AsyncThrowingStream<ChatMessage, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                do {
                    guard let url = URL(string: baseUrl + "v1/chat/completions") else {
                        throw NSError(
                            domain: "OpenAIService", code: -1,
                            userInfo: [
                                NSLocalizedDescriptionKey: "Invalid OpenAI URL configuration"
                            ])
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue(
                        "Bearer \(settings.llmService.apiKey)", forHTTPHeaderField: "Authorization")

                    var parameters: [String: Any] = [
                        "model": model,
                        "messages": messages.map {
                            ["role": $0.role.rawValue, "content": $0.content]
                        },
                        "stream": true,
                        "temperature": settings.llmService.temperature,
                        "top_p": settings.llmService.topP,
                    ]

                    request.httpBody = try JSONSerialization.data(withJSONObject: parameters)

                    let session = createSession()
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let httpResponse = response as? HTTPURLResponse else {
                        throw NSError(
                            domain: "OpenaiService",
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

                        logger.log("Openai chat stream failed: \(errorMessage)", level: .error)
                        throw NSError(
                            domain: "OpenaiService",
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
                                !line.isEmpty,
                                line.hasPrefix("data: "),
                                let jsonData = line.dropFirst(6).data(using: .utf8),
                                let chatMessage = try? parseStreamResponse(data: jsonData)
                            {
                                continuation.yield(chatMessage)
                            }
                            buffer = Data()
                        }
                    }

                    // Handle any remaining data
                    if !buffer.isEmpty,
                        let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(
                            in: .whitespacesAndNewlines),
                        !line.isEmpty,
                        line.hasPrefix("data: "),
                        let jsonData = line.dropFirst(6).data(using: .utf8),
                        let chatMessage = try? parseStreamResponse(data: jsonData)
                    {
                        continuation.yield(chatMessage)
                    }

                    continuation.finish()
                } catch {
                    logger.log(
                        "Openai chat stream failed: \(error.localizedDescription)", level: .error)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func parseStreamResponse(data: Data) throws -> ChatMessage? {
        if let json = try? JSONSerialization.jsonObject(with: data, options: [])
            as? [String: Any]
        {
            if let choices = json["choices"] as? [[String: Any]],
                let firstChoice = choices.first,
                let delta = firstChoice["delta"] as? [String: Any]
            {
                let content = delta["content"] as? String ?? ""
                let usage = json["usage"] as? [String: Any]
                let promptTokens = usage?["prompt_tokens"] as? Int ?? 0
                let completionTokens = usage?["completion_tokens"] as? Int ?? 0
                let model = json["model"] as? String
                return ChatMessage(
                    role: .assistant, content: content, promptEvalCount: promptTokens,
                    evalCount: completionTokens, model: model)
            }
        }
        return nil
    }

    public func chat(
        messages: [ChatMessage], model: String,
        tools: [ChatMessage.Tool]? = nil,
        formatter: ChatMessage.OutputFormatter? = nil
    )
        async throws
        -> ChatMessage
    {
        guard let url = makeUrl("v1/chat/completions") else {
            throw NSError(
                domain: "OpenaiService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Openai URL configuration"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(settings.llmService.apiKey)", forHTTPHeaderField: "Authorization")
        let toolsJson: [[String: Any]] =
            if let tools = tools {
                LLMServiceFactory.toolsToDict(tools)
            } else {
                []
            }

        var httpBody: [String: Any] = [
            "model": model,
            "messages": messages.map { message in
                [
                    "role": message.role.rawValue,
                    "content": message.content,
                ]
            },
            "stream": false,
            "temperature": settings.llmService.temperature,
            "top_p": settings.llmService.topP,
        ]
        if tools != nil && !toolsJson.isEmpty {
            httpBody["tools"] = toolsJson
        }
        if formatter != nil {
            httpBody["response_format"] = ["type": "json_object"]
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: httpBody)
        let session = createSession()
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "OpenaiService",
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

            logger.log("Openai chat failed: \(errorMessage)", level: .error)
            throw NSError(
                domain: "OpenaiService",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Chat request failed: \(errorMessage)"])
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let firstChoice = choices.first,
            let message = firstChoice["message"] as? [String: Any],
            let content = message["content"] as? String,
            let usage = json["usage"] as? [String: Any],
            let promptTokens = usage["prompt_tokens"] as? Int,
            let completionTokens = usage["completion_tokens"] as? Int,
            let model = json["model"] as? String
        else {
            throw NSError(
                domain: "OpenaiService",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }

        // Parse tool calls if present
        var toolCalls: [ChatMessage.ToolCall]?
        if let toolCallsJson = message["tool_calls"] as? [[String: Any]] {
            toolCalls = toolCallsJson.compactMap { toolCallJson in
                guard let functionJson = toolCallJson["function"] as? [String: Any] else {
                    return nil
                }
                guard let name = functionJson["name"] as? String,
                    let argumentsString = functionJson["arguments"] as? String,
                    let arguments = try? JSONSerialization.jsonObject(
                        with: argumentsString.data(using: .utf8)!, options: []) as? [String: String]
                else { return nil }
                return ChatMessage.ToolCall(name: name, arguments: arguments)
            }
        }

        return ChatMessage(
            role: .assistant,
            content: content,
            toolCalls: toolCalls,
            promptEvalCount: promptTokens,
            evalCount: completionTokens,
            model: model
        )
    }

    public nonisolated func listModels() async throws -> [any ModelProtocol] {
        let models = try await Task { @MainActor in
            guard let url = URL(string: baseUrl + "v1/models") else {
                throw NSError(
                    domain: "OpenAIService", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid OpenAI URL configuration"])
            }

            var request = URLRequest(url: url)
            request.setValue(
                "Bearer \(settings.llmService.apiKey)", forHTTPHeaderField: "Authorization")
            request.httpMethod = "GET"

            let session = createSession()
            do {
                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(
                        domain: "OpenaiService",
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

                    logger.log("Openai list models failed: \(errorMessage)", level: .error)
                    throw NSError(
                        domain: "OpenaiService",
                        code: httpResponse.statusCode,
                        userInfo: [
                            NSLocalizedDescriptionKey: "List models request failed: \(errorMessage)"
                        ])
                }

                if let json = try JSONSerialization.jsonObject(with: data, options: [])
                    as? [String: Any],
                    let models = json["data"] as? [[String: Any]]
                {
                    return try models.map { modelDict in
                        guard let name = modelDict["id"] as? String,
                            let owner = modelDict["owned_by"] as? String
                        else {
                            throw NSError(
                                domain: "OpenaiService", code: -3,
                                userInfo: [NSLocalizedDescriptionKey: "Invalid model data format"])
                        }
                        return Model(name: name, owner: owner, size: 0, modified_at: "")
                    }
                } else {
                    throw NSError(
                        domain: "OpenaiService", code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
                }
            } catch {
                logger.log(
                    "Failed to list Openai models: \(error.localizedDescription)", level: .error)
                throw error
            }
        }.value

        return models
    }
}
