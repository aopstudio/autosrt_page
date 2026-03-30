import Foundation

public struct Subtitle: Identifiable, Codable, Equatable {
    public let id: UUID
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public var originalSourceText: String
    public var originalTranslatedText: String
    public var sourceText: String {
        didSet {
            if sourceText != oldValue {
                isSourceEdited = true
                originalSourceText = oldValue 
            }
        }
    }
    public var translatedText: String {
        didSet {
            if translatedText != oldValue {
                isTranslatedEdited = true
                originalTranslatedText = oldValue
            }
        }
    }
    public var index: Int
    public var isSourceEdited: Bool = false
    public var isTranslatedEdited: Bool = false
    
    enum CodingKeys: String, CodingKey {
        case id, startTime, endTime, originalSourceText, originalTranslatedText, sourceText, translatedText, index, isSourceEdited, isTranslatedEdited
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(startTime, forKey: .startTime)
        try container.encode(endTime, forKey: .endTime)
        try container.encode(originalSourceText, forKey: .originalSourceText)
        try container.encode(originalTranslatedText, forKey: .originalTranslatedText)
        try container.encode(sourceText, forKey: .sourceText)
        try container.encode(translatedText, forKey: .translatedText)
        try container.encode(index, forKey: .index)
        try container.encode(isSourceEdited, forKey: .isSourceEdited)
        try container.encode(isTranslatedEdited, forKey: .isTranslatedEdited)
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        startTime = try container.decode(TimeInterval.self, forKey: .startTime)
        endTime = try container.decode(TimeInterval.self, forKey: .endTime)
        originalSourceText = try container.decode(String.self, forKey: .originalSourceText)
        originalTranslatedText = try container.decode(String.self, forKey: .originalTranslatedText)
        sourceText = try container.decode(String.self, forKey: .sourceText)
        translatedText = try container.decode(String.self, forKey: .translatedText)
        index = try container.decode(Int.self, forKey: .index)
        isSourceEdited = try container.decode(Bool.self, forKey: .isSourceEdited)
        isTranslatedEdited = try container.decode(Bool.self, forKey: .isTranslatedEdited)
    }
    
    public init(id: UUID = UUID(), startTime: TimeInterval, endTime: TimeInterval, sourceText: String, translatedText: String, index: Int = 0, sourceLanguage: String? = nil, translatedLanguage: String? = nil) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.originalSourceText = ""
        self.originalTranslatedText = ""
        self.index = index
        self.isSourceEdited = false
        self.isTranslatedEdited = false
    }
    
    public var displayText: String {
        "\(sourceText)\n\(translatedText)"
    }
    
    public static func mergeBilingualSubtitles(english: [Subtitle], translated: [Subtitle]) -> [Subtitle] {
        guard english.count == translated.count else {
            // If counts don't match, use whichever has text
            return english.map { Subtitle(startTime: $0.startTime, endTime: $0.endTime, sourceText: $0.sourceText, translatedText: "", index: 0) } +
                   translated.map { Subtitle(startTime: $0.startTime, endTime: $0.endTime, sourceText: "", translatedText: $0.translatedText, index: 0) }
        }
        
        return zip(english, translated).map { en, tr in
            Subtitle(
                startTime: en.startTime,
                endTime: en.endTime,
                sourceText: en.sourceText,
                translatedText: tr.translatedText,
                index: 0
            )
        }
    }
}
