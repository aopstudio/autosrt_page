import Foundation
import Sparkle

final class UpdaterService: NSObject, ObservableObject {
    private var updaterDelegate: CustomUpdaterDelegate
    private let logger = LoggerService.shared

    private var updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    static let shared = UpdaterService()

    override init() {
        updaterDelegate = CustomUpdaterDelegate()
        // Initialize properties before super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: updaterDelegate,
            userDriverDelegate: nil
        )

        super.init()
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
