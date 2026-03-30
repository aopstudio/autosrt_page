import SwiftUI

class SettingsService {
    static let shared = SettingsService()
    private var settingsWindowController: NSWindowController?
    
    private init() {}
    
    func showSettings() {
        if let existingWindow = settingsWindowController?.window {
            existingWindow.makeKeyAndOrderFront(nil)
            return
        }
        
        let settingsView = SettingsView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.contentView = NSHostingView(rootView: settingsView)
        
        settingsWindowController = NSWindowController(window: window)
        settingsWindowController?.showWindow(nil)
    }
}
