import AppKit
import Foundation

/// Screenshot failures the UI can offer a one-click fix for.
enum ScreenshotError: LocalizedError {
    /// macOS blocked writing to the Desktop (fix: allow it in Privacy & Security).
    case desktopPermission

    var errorDescription: String? {
        switch self {
        case .desktopPermission:
            return "macOS didn't allow RunXcodeApp to save to the Desktop."
        }
    }
}

/// Per-project helper actions: device screenshots and opening the project in an IDE / Terminal.
enum DeviceTools {
    // MARK: - Screenshots

    /// Any destination can be tried; `screenshot(of:label:)` explains what went wrong if it can't.
    static func canScreenshot(_ destination: Simulator?) -> Bool { destination != nil }

    /// Screenshots are saved to the Desktop. (The first time, macOS may ask to allow
    /// RunXcodeApp to access the Desktop folder; it must be allowed for captures to save.)
    static var screenshotsFolder: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }

    /// Saves a PNG of the destination's screen and returns its URL.
    static func screenshot(of destination: Simulator, label: String) async throws -> URL {
        let url = screenshotURL(label: label)
        do {
            try await capture(destination, to: url)
        } catch let error as ScreenshotError {
            throw error
        } catch {
            // simctl / adb report a blocked Desktop as "Operation not permitted".
            let text = error.localizedDescription.lowercased()
            if text.contains("not permitted") || text.contains("permission denied") {
                throw ScreenshotError.desktopPermission
            }
            throw error
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RunError.toolMissing("The screenshot command finished but no image was written.")
        }
        return url
    }

    private static func capture(_ destination: Simulator, to url: URL) async throws {
        switch destination.kind {
        case .simulator:
            guard destination.isBooted else {
                throw RunError.toolMissing("\(destination.name) is shut down. Boot it first.")
            }
            try await Shell.checked(Shell.xcrunPath, ["simctl", "io", destination.udid, "screenshot", url.path])
        case .device:
            // Xcode command-line tools only: `xcrun simctl io <udid> screenshot <file>`.
            // simctl is meant for simulators, so a physical device may be refused; show Xcode's own error.
            guard !destination.isOffline else {
                throw RunError.toolMissing("\(destination.name) is offline.")
            }
            let result = try await Shell.run(Shell.xcrunPath, ["simctl", "io", destination.udid, "screenshot", url.path])
            if !result.succeeded || !FileManager.default.fileExists(atPath: url.path) {
                let output = (result.stderr.isEmpty ? result.stdout : result.stderr)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw RunError.toolMissing(
                    "xcrun simctl couldn't capture \(destination.name) (simctl only supports simulators)."
                        + (output.isEmpty ? "" : " Xcode said: \(output)")
                )
            }
        case .androidEmulator, .androidDevice:
            guard let adb = AndroidSDK.adb else { throw AndroidError.sdkNotFound }
            guard let serial = destination.serial else {
                throw RunError.toolMissing("\(destination.name) isn't running or connected.")
            }
            let remote = "/sdcard/runxcodeapp-screenshot.png"
            try await Shell.checked(adb, ["-s", serial, "shell", "screencap", "-p", remote])
            try await Shell.checked(adb, ["-s", serial, "pull", remote, url.path])
            _ = try? await Shell.run(adb, ["-s", serial, "shell", "rm", remote])
        }
    }

    /// Copies the image file to the clipboard.
    static func copyImage(at url: URL) {
        guard let image = NSImage(contentsOf: url) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private static func screenshotURL(label: String) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let safe = label.replacingOccurrences(of: "/", with: "-")
        return screenshotsFolder.appendingPathComponent("\(safe) \(formatter.string(from: Date())).png")
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
