import Foundation

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {

    public enum Role: String, Codable, Equatable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public struct ToolCall: Codable, Identifiable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let arguments: [String: String]
        public var responseStatus: Bool?
        public var responseResult: String?
        public var responseError: String?
        public var responseReference: String?

        public init(name: String, arguments: [String: String], responseStatus: Bool? = nil, responseResult: String? = nil, responseError: String? = nil, responseReference: String? = nil) {
            self.id = UUID().uuidString
            self.name = name
            self.arguments = arguments
            self.responseStatus = responseStatus
            self.responseResult = responseResult
            self.responseError = responseError
            self.responseReference = responseReference
        }

        public static func == (lhs: ChatMessage.ToolCall, rhs: ChatMessage.ToolCall) -> Bool {
            return lhs.id == rhs.id && lhs.name == rhs.name && lhs.arguments == rhs.arguments
                && lhs.responseStatus == rhs.responseStatus
                && lhs.responseResult == rhs.responseResult
                && lhs.responseError == rhs.responseError
                && lhs.responseReference == rhs.responseReference
        }
    }

    public struct ToolParameter: Codable, Identifiable, Equatable, Sendable {
        public var id: String { name }
        public let name: String
        public let description: String
        public let type: String
        public let defaultValue: String?

        public init(
            name: String, description: String, type: String, defaultValue: String? = nil
        ) {
            self.name = name
            self.description = description
            self.type = type
            self.defaultValue = defaultValue
        }

        public static func == (lhs: ChatMessage.ToolParameter, rhs: ChatMessage.ToolParameter)
            -> Bool
        {
            return lhs.name == rhs.name && lhs.description == rhs.description
                && lhs.type == rhs.type && lhs.defaultValue == rhs.defaultValue
        }
    }

    public struct Tool: Codable, Identifiable, Equatable, @unchecked Sendable {
        public var id: String
        public let name: String
        public let description: String
        public let parameters: [ToolParameter]
        public let handler: (ToolCall) async throws -> AsyncStream<ChatMessage>

        private enum CodingKeys: String, CodingKey {
            case id, name, description, parameters
        }

        public init(
            name: String, description: String, parameters: [ToolParameter],
            handler: @escaping (ToolCall) async throws -> AsyncStream<ChatMessage>
        ) {
            self.id = UUID().uuidString
            self.name = name
            self.description = description
            self.parameters = parameters
            self.handler = handler
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.name = try container.decode(String.self, forKey: .name)
            self.description = try container.decode(String.self, forKey: .description)
            self.parameters = try container.decode([ToolParameter].self, forKey: .parameters)
            self.handler = { (_: ToolCall) async throws -> AsyncStream<ChatMessage> in
                return AsyncStream { _ in }
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(description, forKey: .description)
            try container.encode(parameters, forKey: .parameters)
        }

        public static func == (lhs: ChatMessage.Tool, rhs: ChatMessage.Tool) -> Bool {
            return lhs.id == rhs.id && lhs.name == rhs.name && lhs.description == rhs.description
                && lhs.parameters == rhs.parameters
        }
    }

    // MARK: - Output formatter property
    public struct OutputFormatterProperty: Codable, Equatable, Sendable {
        public let type: String 
        public let name: String
    }

    // MARK: - Output Formatter
    public struct OutputFormatter: Codable, Equatable, Sendable {
        public let type: String 
        public let properties: [OutputFormatterProperty]
        public var propertiesDict: [String: Any] {
            var result: [String: Any] = [:]
            for property in properties {
                result[property.name] = ["type": property.type]
            }
            return result
        }
        public let required: [String]

        public var asDict: [String: Any] {
            var result: [String: Any] = [:]
            result["type"] = type
            result["properties"] = propertiesDict
            result["required"] = required
            return result
        }
    }

    public let id: UUID
    public var role: Role
    public var content: String
    public let timestamp: TimeInterval
    public var toolCalls: [ToolCall]?
    public let images: [String]?
    public let outputFormatter: OutputFormatter?
    // for response only
    public var spendTime: TimeInterval?
    public var doneReason: String?
    public var done: Bool?
    public var totalDuration: Int64?
    public var loadDuration: Int64?
    public var promptEvalCount: Int?
    public var promptEvalDuration: Int64?
    public var evalCount: Int?
    public var evalDuration: Int64?
    public var model: String?

    public init(
        role: Role,
        content: String,
        toolCalls: [ToolCall]? = nil,
        images: [String]? = nil,
        outputFormatter: OutputFormatter? = nil,
        spendTime: TimeInterval? = nil,
        doneReason: String? = nil,
        done: Bool? = nil,
        totalDuration: Int64? = nil,
        loadDuration: Int64? = nil,
        promptEvalCount: Int? = nil,
        promptEvalDuration: Int64? = nil,
        evalCount: Int? = nil,
        evalDuration: Int64? = nil,
        model: String? = nil,
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date().timeIntervalSince1970
        self.toolCalls = toolCalls
        self.images = images
        self.outputFormatter = outputFormatter
        self.spendTime = spendTime
        self.doneReason = doneReason
        self.done = done
        self.totalDuration = totalDuration
        self.loadDuration = loadDuration
        self.promptEvalCount = promptEvalCount
        self.promptEvalDuration = promptEvalDuration
        self.evalCount = evalCount
        self.evalDuration = evalDuration
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, images, outputFormatter, toolCalls, spendTime, doneReason, done,
        totalDuration, loadDuration, promptEvalCount, promptEvalDuration, evalCount, evalDuration, model, references
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(Role.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.timestamp = try container.decode(Double.self, forKey: .timestamp)
        self.toolCalls = try container.decodeIfPresent([ToolCall].self, forKey: .toolCalls)
        self.images = try container.decodeIfPresent([String].self, forKey: .images)
        self.outputFormatter = try container.decodeIfPresent(OutputFormatter.self, forKey: .outputFormatter)
        self.spendTime = try container.decodeIfPresent(Double.self, forKey: .spendTime)
        self.doneReason = try container.decodeIfPresent(String.self, forKey: .doneReason)
        self.done = try container.decodeIfPresent(Bool.self, forKey: .done)
        self.totalDuration = try container.decodeIfPresent(Int64.self, forKey: .totalDuration)
        self.loadDuration = try container.decodeIfPresent(Int64.self, forKey: .loadDuration)
        self.promptEvalCount = try container.decodeIfPresent(Int.self, forKey: .promptEvalCount)
        self.promptEvalDuration = try container.decodeIfPresent(Int64.self, forKey: .promptEvalDuration)
        self.evalCount = try container.decodeIfPresent(Int.self, forKey: .evalCount)
        self.evalDuration = try container.decodeIfPresent(Int64.self, forKey: .evalDuration)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encode(images, forKey: .images)
        try container.encode(outputFormatter, forKey: .outputFormatter)
        try container.encode(spendTime, forKey: .spendTime)
        try container.encode(doneReason, forKey: .doneReason)
        try container.encode(done, forKey: .done)
        try container.encode(totalDuration, forKey: .totalDuration)
        try container.encode(loadDuration, forKey: .loadDuration)
        try container.encode(promptEvalCount, forKey: .promptEvalCount)
        try container.encode(promptEvalDuration, forKey: .promptEvalDuration)
        try container.encode(evalCount, forKey: .evalCount)
        try container.encode(evalDuration, forKey: .evalDuration)
        try container.encode(model, forKey: .model)
    }

    public static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        return lhs.id == rhs.id && lhs.role == rhs.role && lhs.content == rhs.content
            && lhs.timestamp == rhs.timestamp && lhs.toolCalls == rhs.toolCalls
            && lhs.images == rhs.images
            && lhs.outputFormatter == rhs.outputFormatter && lhs.spendTime == rhs.spendTime
            && lhs.doneReason == rhs.doneReason && lhs.done == rhs.done
            && lhs.totalDuration == rhs.totalDuration && lhs.loadDuration == rhs.loadDuration
            && lhs.promptEvalCount == rhs.promptEvalCount
            && lhs.promptEvalDuration == rhs.promptEvalDuration && lhs.evalCount == rhs.evalCount
            && lhs.evalDuration == rhs.evalDuration && lhs.model == rhs.model
    }

    // convert to json
    func jsonText() throws -> String {
        let encoder = JSONEncoder()
        return try String(data: encoder.encode(self), encoding: .utf8)!
    }
}
