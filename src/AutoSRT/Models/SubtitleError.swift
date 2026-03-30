import Foundation

enum SubtitleError: Error {
    case noVideoSelected
    case videoNotFound
    case srtFileNotFound
    case invalidFormat
    case failedToSaveSRT
    case failedToReadSRT
    case processingError(String)

    var localizedDescription: String {
        switch self {
        case .noVideoSelected:
            return "No video selected"
        case .videoNotFound:
            return "Video not found"
        case .srtFileNotFound:
            return "SRT file not found"
        case .failedToSaveSRT:
            return "Failed to save SRT file"
        case .failedToReadSRT:
            return "Failed to read SRT file"
        case .invalidFormat:
            return "Invalid subtitle format"
        case .processingError(let message):
            return "Processing error: \(message)"
        }
    }
}
