import AppKit
import Foundation

/// Per-project helper actions: device screenshots and opening the project in an IDE / Terminal.
enum DeviceTools {
    // MARK: - Screenshots

    static func canScreenshot(_ destination: Simulator?) -> Bool {
        guard let destination else { return false }
        switch destination.kind {
        case .simulator, .androidEmulator: return destination.isBooted
        case .androidDevice: return !destination.isOffline
        case .device: return false
        }
    }

    /// Saves a PNG of the destination's screen to the Desktop and returns its URL.
    static func screenshot(of destination: Simulator, label: String) async throws -> URL {
        let url = screenshotURL(label: label)
        switch destination.kind {
        case .simulator:
            try await Shell.checked(Shell.xcrunPath, ["simctl", "io", destination.udid, "screenshot", url.path])
        case .androidEmulator, .androidDevice:
            guard let adb = AndroidSDK.adb else { throw AndroidError.sdkNotFound }
            guard let serial = destination.serial else {
                throw RunError.toolMissing("\(destination.name) isn't running.")
            }
            let remote = "/sdcard/runxcodeapp-screenshot.png"
            try await Shell.checked(adb, ["-s", serial, "shell", "screencap", "-p", remote])
            try await Shell.checked(adb, ["-s", serial, "pull", remote, url.path])
            _ = try? await Shell.run(adb, ["-s", serial, "shell", "rm", remote])
        case .device:
            throw RunError.toolMissing("Screenshots of physical Apple devices aren't supported. Use Xcode › Devices and Simulators.")
        }
        return url
    }

    /// Copies the image file to the clipboard.
    static func copyImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private static func screenshotURL(label: String) -> URL {
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safe = label.replacingOccurrences(of: "/", with: "-")
        return desktop.appendingPathComponent("\(safe) \(formatter.string(from: Date())).png")
    }

    // MARK: - Opening the project

    private static let vsCode = "com.microsoft.VSCode"
    private static let androidStudio = "com.google.android.studio"
    private static let terminal = "com.apple.Terminal"

    /// Title and SF Symbol for the "open in IDE" action.
    static func ideAction(for project: XcodeProject) -> (title: String, symbol: String) {
        switch project.kind {
        case .workspace, .project:
            return ("Open in Xcode", "hammer")
        case .android:
            return ("Open in Android Studio", "cube")
        case .flutter:
            return appURL(vsCode) != nil ? ("Open in VS Code", "chevron.left.forwardslash.chevron.right")
                                         : ("Open in Android Studio", "cube")
        }
    }

    static func openInIDE(_ project: XcodeProject) {
        switch project.kind {
        case .workspace, .project:
            NSWorkspace.shared.open(project.url)
        case .android:
            open(project.url, with: androidStudio)
        case .flutter:
            open(project.url, with: appURL(vsCode) != nil ? vsCode : androidStudio)
        }
    }

    static func openInTerminal(_ project: XcodeProject) {
        open(project.directory, with: terminal)
    }

    private static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private static func open(_ url: URL, with bundleID: String) {
        guard let app = appURL(bundleID) else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }
}
