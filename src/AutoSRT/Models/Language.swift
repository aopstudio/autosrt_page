import Foundation

enum Language: String, CaseIterable {
    case None = "None"
    case English = "English"
    case Spanish = "Spanish"
    case SimplifiedChinese = "Simplified Chinese"
    case TraditionalChinese = "Traditional Chinese"
    case Arabic = "Arabic"
    case French = "French"
    case German = "German"
    case Portuguese = "Portuguese"
    case Russian = "Russian"
    case Japanese = "Japanese"
    case Italian = "Italian"
    case Korean = "Korean"
    case Thai = "Thai"
    case Finnish = "Finnish"
    case Polish = "Polish"

    var target: String {
        switch self {
        case .English: return "English"
        case .Spanish: return "Spanish"
        case .SimplifiedChinese: return "Simplified Chinese"
        case .TraditionalChinese: return "Traditional Chinese"
        case .Arabic: return "Arabic"
        case .French: return "French"
        case .German: return "German"
        case .Portuguese: return "Portuguese"
        case .Russian: return "Russian"
        case .Japanese: return "Japanese"
        case .Italian: return "Italian"
        case .Korean: return "Korean"
        case .Thai: return "Thai"
        case .Finnish: return "Finnish"
        case .Polish: return "Polish"
        case .None: return "None"
        }
    }

    var displayName: String {
        "\(target)"
    }

    var whisperCode: String {
        switch self {
        case .English: return "en"
        case .Spanish: return "es"
        case .SimplifiedChinese: return "zh"
        case .TraditionalChinese: return "zh"
        case .Arabic: return "ar"
        case .French: return "fr"
        case .German: return "de"
        case .Portuguese: return "pt"
        case .Russian: return "ru"
        case .Japanese: return "ja"
        case .Italian: return "it"
        case .Korean: return "ko"
        case .Thai: return "th"
        case .Finnish: return "fi"
        case .Polish: return "pl"
        case .None: return "auto"
        }
    }
    
    static func fromCode(_ code: String) -> Language {
        switch code {
        case "en": return .English
        case "es": return .Spanish
        case "zh": return .SimplifiedChinese
        case "ar": return .Arabic
        case "fr": return .French
        case "de": return .German
        case "pt": return .Portuguese
        case "ru": return .Russian
        case "ja": return .Japanese
        case "it": return .Italian
        case "ko": return .Korean
        case "th": return .Thai
        case "fi": return .Finnish
        case "pl": return .Polish
        default: return .English
        }
    }
}
