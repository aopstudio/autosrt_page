import Foundation
import os.log

public enum LoggingLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARNING"
    case error = "ERROR"
}

public final class LoggerService: @unchecked Sendable {
    public static let shared = LoggerService()
    private let logger: Logger
    
    private init() {
        self.logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.llmsurf.app", category: "LLMSurf")
    }
    
    public func log(_ message: String, level: LoggingLevel = .info, file: String = #file, function: String = #function, line: Int = #line) {
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(Date())] [\(level.rawValue)] [\(fileName):\(line)] \(function) - \(message)"
        
        switch level {
        case .debug:
            logger.debug("\(logMessage)")
        case .info:
            logger.info("\(logMessage)")
        case .warning:
            logger.warning("\(logMessage)")
        case .error:
            logger.error("\(logMessage)")
        }
    }
}
