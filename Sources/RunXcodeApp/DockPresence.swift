import AppKit

/// Shows the app in the Dock (and the app switcher) while a commit or file browser window is open,
/// and goes back to menu-bar-only when the last one closes.
enum DockPresence {
    private static var windows = Set<ObjectIdentifier>()

    static func track(_ window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard !windows.contains(id) else { return }
        windows.insert(id)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            windows.remove(id)
            if let token { NotificationCenter.default.removeObserver(token) }
            guard windows.isEmpty else { return }
            DispatchQueue.main.async {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
