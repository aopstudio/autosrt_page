import Cocoa
import Sparkle
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let updaterService = UpdaterService.shared
    private let settingsService = SettingsService.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create the SwiftUI view that provides the window contents.
        let contentView = ContentView()

        // Create the window and set the content view.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AutoSRT"
        window.center()
        window.setFrameAutosaveName("Main Window")
        window.contentView = NSHostingView(rootView: contentView)
        window.makeKeyAndOrderFront(nil)

        setupMenu()
    }

    private func setupMenu() {
        let mainMenu = NSMenu()

        // Application Menu
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // About Item
        appMenu.addItem(
            withTitle: "About AutoSRT",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())

        // Check for Updates
        appMenu.addItem(
            withTitle: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())

        // Preferences
        appMenu.addItem(
            withTitle: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())

        // Services Menu
        let servicesMenu = NSMenu()
        let servicesMenuItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesMenuItem.submenu = servicesMenu
        appMenu.addItem(servicesMenuItem)
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(NSMenuItem.separator())

        // Standard close/hide items
        appMenu.addItem(
            withTitle: "Hide AutoSRT", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"
        )
        let hideOthersItem = NSMenuItem(
            title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit AutoSRT", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")

        NSApp.mainMenu = mainMenu
    }

    @objc private func checkForUpdates() {
        updaterService.checkForUpdates()
    }

    @objc private func openPreferences() {
        settingsService.showSettings()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
    
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}
