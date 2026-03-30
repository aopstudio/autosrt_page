import AppKit
import Foundation

public enum AnalyticsEvent: String {
    case appLaunched = "app_launched"
    case generateSubtitleStarted = "generate_subtitle_started"
    case generateSubtitleCompleted = "generate_subtitle_completed"
    case videoRenderingStarted = "video_rendering_started"
    case videoRenderingCompleted = "video_rendering_completed"
    case videoRenderingFailed = "video_rendering_failed"
    case modelSelected = "model_selected"
    case qualitySelected = "quality_selected"
    case fontSizeSelected = "font_size_selected"
    case errorOccurred = "error_occurred"
    case donateViewOpened = "donate_view_opened"
    case videoSelected = "video_selected"
    case sourceLanguageSelected = "source_language_selected"
    case targetLanguageSelected = "target_language_selected"

    // Summary related events
    case summaryViewOpened = "summary_view_opened"
    case summaryGenerationStarted = "summary_generation_started"
    case summaryGenerationCompleted = "summary_generation_completed"
    case summaryGenerationFailed = "summary_generation_failed"

    // Subtitle edit events
    case subtitleEditViewOpened = "subtitle_edit_view_opened"
    case subtitleEditViewSaved = "subtitle_edit_view_saved"
    case subtitleSearchStarted = "subtitle_search_started"
    case subtitleSearchCompleted = "subtitle_search_completed"
    case subtitleReplaceStarted = "subtitle_replace_started"
    case subtitleReplaceCompleted = "subtitle_replace_completed"
    case subtitleDocumentUploaded = "subtitle_document_uploaded"

    // Settings related events
    case settingsViewOpened = "settings_view_opened"
    case settingsSaved = "settings_saved"
    case ollamaUrlUpdated = "ollama_url_updated"
}

public class AnalyticsService {
    public static let shared = AnalyticsService()
    private let logger = LoggerService.shared
    private let deviceService = DeviceService.shared
    private let measurementID = "G-G0EH7J4RFH"
    private let apiSecret = "Uv1DTnRASe2DXrQk_2NEzw"

    private var sessionId: String
    private var clientId: String
    private let deviceInfo: [String: String]
    private let systemInfo: [String: String]
    private let locale: Locale

    private init() {
        // Generate a unique session ID
        sessionId = UUID().uuidString

        // Get or create a persistent client ID
        if let existingClientId = UserDefaults.standard.string(forKey: "ga_client_id") {
            clientId = existingClientId
        } else {
            clientId = deviceService.getSystemUUID()
            UserDefaults.standard.set(clientId, forKey: "ga_client_id")
        }

        // Get device information
        deviceInfo = deviceService.getDeviceInfo()

        // Get system information
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersionString =
            "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        let osName = "macOS"
        let osFullName = {
            switch osVersion.majorVersion {
            case 14: return "Sonoma"
            case 13: return "Ventura"
            case 12: return "Monterey"
            case 11: return "Big Sur"
            case 10:
                switch osVersion.minorVersion {
                case 15: return "Catalina"
                case 14: return "Mojave"
                case 13: return "High Sierra"
                default: return "Unknown"
                }
            default: return "Unknown"
            }
        }()

        systemInfo = [
            "os_version": osVersionString,
            "os_name": osName,
            "os_full_name": osFullName,
            "architecture": deviceService.getSystemArchitecture() ?? "unknown",
        ]

        // Get locale information
        locale = Locale.current
    }

    private func getCountryInfo() -> [String: String] {
        var info: [String: String] = [:]

        // Get country from system locale
        if #available(macOS 13, *) {
            if let countryCode = locale.region?.identifier {
                info["country_code"] = countryCode

                // Get full country name
                if let countryName = locale.localizedString(forRegionCode: countryCode) {
                    info["country_name"] = countryName
                }
            }
        } else {
            // Fallback on earlier versions
        }

        // Get language information
        if #available(macOS 13, *) {
            info["language_code"] = locale.language.languageCode?.identifier ?? "unknown"
        } else {
            // Fallback on earlier versions
        }
        if #available(macOS 13, *) {
            if let languageName = locale.localizedString(
                forLanguageCode: locale.language.languageCode?.identifier ?? "")
            {
                info["language_name"] = languageName
            }
        } else {
            // Fallback on earlier versions
        }

        // Get timezone information
        let timezone = TimeZone.current
        info["timezone"] = timezone.identifier
        info["timezone_offset"] = "\(timezone.secondsFromGMT()/3600)"

        return info
    }

    public func trackEvent(_ event: AnalyticsEvent, parameters: [String: Any] = [:]) {
        var eventParams = parameters
        eventParams["engagement_time_msec"] = "100"

        // Add device information
        eventParams["device_uuid"] = deviceInfo["uuid"]
        eventParams["device_model"] = deviceInfo["model_identifier"]

        // Add system information
        eventParams["os_version"] = systemInfo["os_version"]
        eventParams["os_name"] = systemInfo["os_name"]
        eventParams["os_full_name"] = systemInfo["os_full_name"]
        eventParams["architecture"] = systemInfo["architecture"]

        // Add country and locale information
        let countryInfo = getCountryInfo()
        eventParams["country_code"] = countryInfo["country_code"]
        eventParams["country_name"] = countryInfo["country_name"]
        eventParams["language_code"] = countryInfo["language_code"]
        eventParams["language_name"] = countryInfo["language_name"]
        eventParams["timezone"] = countryInfo["timezone"]
        eventParams["timezone_offset"] = countryInfo["timezone_offset"]

        // Add app information
        eventParams["app_version"] =
            Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"

        eventParams["session_id"] = sessionId

        let payload: [String: Any] = [
            "client_id": clientId,
            "user_id": clientId,
            "events": [
                [
                    "name": event.rawValue,
                    "params": eventParams,
                ]
            ],
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload) else {
            logger.log("Failed to serialize analytics payload", level: .error)
            return
        }

        sendAnalyticsData(jsonData)
    }

    public func trackError(_ error: Error, context: String) {
        trackEvent(
            .errorOccurred,
            parameters: [
                "error_type": String(describing: type(of: error)),
                "error_message": error.localizedDescription,
                "error_context": context,
            ])
    }

    private func sendAnalyticsData(_ data: Data) {
        let urlString =
            "https://www.google-analytics.com/mp/collect?measurement_id=\(measurementID)&api_secret=\(apiSecret)"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            if let error = error {
                self?.logger.log("Analytics error: \(error.localizedDescription)", level: .error)
            }
        }.resume()
    }
}
