import Foundation

// Protocol defining what a Model should be
public protocol ModelProtocol: Sendable {
    var name: String { get }
    var owner: String { get }
}

// Protocol defining the common interface for LLM services
public protocol LLMService: Sendable {
    func checkAvailability() async -> Bool
    func chatStream(messages: [ChatMessage], model: String, formatter: ChatMessage.OutputFormatter?)
        -> AsyncThrowingStream<ChatMessage, Error>
    func chat(
        messages: [ChatMessage], model: String, tools: [ChatMessage.Tool]?,
        formatter: ChatMessage.OutputFormatter?
    ) async throws -> ChatMessage
    func listModels() async throws -> [any ModelProtocol]
}

// Factory class to create the appropriate LLM service based on settings
@MainActor
public final class LLMServiceFactory: @unchecked Sendable {
    private static let settings = Settings.shared
    private static let logger = LoggerService.shared

    @MainActor
    public static func createService() -> any LLMService {
        switch settings.llmService.apiType {
        case .ollama:
            logger.log("Using Ollama service", level: .info)
            return OllamaService.shared
        case .openai:
            logger.log("Using OpenAI service", level: .info)
            return OpenaiService.shared
        }
    }

    public static func toolsToDict(_ myTools: [ChatMessage.Tool]) -> [[String: Any]] {
        myTools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": [
                        "type": "object",
                        "properties": tool.parameters.reduce(into: [String: [String: String]]()) {
                            dict, parameter in
                            dict[parameter.name] = [
                                "type": parameter.type,
                                "description": parameter.description,
                            ]
                        },
                        "required": tool.parameters.map { $0.name },
                    ],
                ],
            ]
        }
    }

    public static func extractJSONs(from text: String) -> [[String: Any]] {
        // Convert the markdown string to a C string (UTF-8) for cmark
        guard let cText = text.cString(using: .utf8) else {
            LoggerService.shared.log("Failed to convert markdown string to C string: \(text)")
            return []
        }

        // Parse the markdown string into an AST root node using cmark
        guard let root = cmark_parse_document(cText, text.utf8.count, CMARK_OPT_DEFAULT) else {
            LoggerService.shared.log("Failed to parse markdown into AST: \(text)")
            return []
        }

        // Ensure the root node is freed when we're done
        defer { cmark_node_free(root) }

        let iter = cmark_iter_new(root)
        var eventType = cmark_iter_next(iter)
        var jsonBlocks: [[String: Any]] = []

        while eventType != CMARK_EVENT_DONE {
            if let node = cmark_iter_get_node(iter) {
                let nodeType = cmark_node_get_type(node)
                if nodeType == CMARK_NODE_CODE_BLOCK {
                    if let literal = cmark_node_get_literal(node) {
                        let literalString = String(cString: literal)

                        if let json = try? JSONSerialization.jsonObject(
                            with: Data(literalString.utf8),
                            options: [.fragmentsAllowed, .json5Allowed]) as? [String: Any]
                        {
                            jsonBlocks.append(json)
                        }
                    }
                }
            }

            eventType = cmark_iter_next(iter)
        }

        cmark_iter_free(iter)

        return jsonBlocks
    }
}
