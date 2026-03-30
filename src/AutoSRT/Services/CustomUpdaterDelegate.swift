import Foundation
import Sparkle

final class CustomUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let logger = LoggerService.shared

    // MARK: - Properties
    @Published var updateAvailable = false
    @Published var lastCheckDate: Date?
    @Published var latestVersion: String?

    // MARK: - SPUUpdaterDelegate Methods
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        if let latestItem = appcast.items.first {
            updateAvailable = true
            latestVersion = latestItem.displayVersionString
            lastCheckDate = Date()
            logger.log("Update available: version \(latestItem.displayVersionString)")
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        return "https://raw.githubusercontent.com/yyaadet/autosrt_page/main/appcast.xml"
    }

    func allowsAutomaticUpdates(for updater: SPUUpdater) -> Bool {
        return true
    }

    func updater(_ updater: SPUUpdater, didFailToUpdateWithError error: Error) {
        logger.log("Update check failed: \(error.localizedDescription)", level: .error)
        updateAvailable = false
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        return true
    }

    // Additional delegate methods
    func updater(
        _ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
        with request: NSMutableURLRequest
    ) {
        logger.log("Starting download of update version \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        logger.log("Successfully downloaded update version \(item.displayVersionString)")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        logger.log("Starting installation of update version \(item.displayVersionString)")
    }
}
