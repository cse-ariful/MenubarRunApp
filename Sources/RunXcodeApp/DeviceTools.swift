import AppKit
import Foundation

/// Per-project helper actions: device screenshots and opening the project in an IDE / Terminal.
enum DeviceTools {
    // MARK: - Screenshots

    /// Any destination can be tried; `screenshot(of:label:)` explains what's missing if it can't.
    static func canScreenshot(_ destination: Simulator?) -> Bool { destination != nil }

    /// Folder screenshots are saved to (~/Pictures/RunXcodeApp). Not the Desktop: macOS asks for
    /// permission before an app writes there, and a missed prompt makes every capture fail.
    static var screenshotsFolder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        return pictures.appendingPathComponent("RunXcodeApp", isDirectory: true)
    }

    /// Saves a PNG of the destination's screen and returns its URL.
    static func screenshot(of destination: Simulator, label: String) async throws -> URL {
        try FileManager.default.createDirectory(at: screenshotsFolder, withIntermediateDirectories: true)
        let url = screenshotURL(label: label)
        switch destination.kind {
        case .simulator:
            guard destination.isBooted else {
                throw RunError.toolMissing("\(destination.name) is shut down. Boot it first.")
            }
            try await Shell.checked(Shell.xcrunPath, ["simctl", "io", destination.udid, "screenshot", url.path])
        case .androidEmulator, .androidDevice:
            guard let adb = AndroidSDK.adb else { throw AndroidError.sdkNotFound }
            guard let serial = destination.serial else {
                throw RunError.toolMissing("\(destination.name) isn't running or connected.")
            }
            let remote = "/sdcard/runxcodeapp-screenshot.png"
            try await Shell.checked(adb, ["-s", serial, "shell", "screencap", "-p", remote])
            try await Shell.checked(adb, ["-s", serial, "pull", remote, url.path])
            _ = try? await Shell.run(adb, ["-s", serial, "shell", "rm", remote])
        case .device:
            guard !destination.isOffline else {
                throw RunError.toolMissing("\(destination.name) is offline.")
            }
            try await appleDeviceScreenshot(destination, to: url)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RunError.toolMissing("The screenshot command finished but no image was written.")
        }
        return url
    }

    /// Physical iPhone/iPad (USB or Wi-Fi). Apple doesn't ship a command-line screenshot tool
    /// (Xcode uses private frameworks), so this uses community tools when they're installed:
    /// pymobiledevice3 (iOS 17+, needs its tunnel daemon) or libimobiledevice's idevicescreenshot.
    private static func appleDeviceScreenshot(_ device: Simulator, to url: URL) async throws {
        var failures: [String] = []

        if let pymobiledevice3 = Shell.which("pymobiledevice3") {
            let attempts: [[String]] = [
                // iOS 17+: goes through the tunnel started by `sudo pymobiledevice3 remote tunneld`.
                ["developer", "dvt", "screenshot", "--tunnel", device.udid, url.path],
                // iOS 16 and earlier (USB / paired Wi-Fi).
                ["developer", "screenshot", "--udid", device.udid, url.path],
            ]
            for arguments in attempts {
                let result = try await Shell.run(pymobiledevice3, arguments)
                if result.succeeded, FileManager.default.fileExists(atPath: url.path) { return }
                failures.append("pymobiledevice3 \(arguments.prefix(3).joined(separator: " ")): \(summary(result))")
            }
        }

        if let idevicescreenshot = Shell.which("idevicescreenshot") {
            var arguments = ["-u", device.udid]
            if device.transport == "Wi-Fi" { arguments.append("-n") }  // network (Wi-Fi) connection
            arguments.append(url.path)
            let result = try await Shell.run(idevicescreenshot, arguments)
            if result.succeeded, FileManager.default.fileExists(atPath: url.path) { return }
            failures.append("idevicescreenshot: \(summary(result))")
        }

        let setup = "Install pymobiledevice3 (brew install pipx && pipx install pymobiledevice3), then keep "
            + "`sudo pymobiledevice3 remote tunneld` running in Terminal. iOS 17+ devices need that tunnel, "
            + "including over Wi-Fi."
        if failures.isEmpty {
            throw RunError.toolMissing("Screenshots of a physical iPhone need a helper tool, because Apple doesn't ship one. " + setup)
        }
        throw RunError.toolMissing("Couldn't capture \(device.name). " + failures.joined(separator: " · ") + ". " + setup)
    }

    private static func summary(_ result: ShellResult) -> String {
        let text = (result.stderr.isEmpty ? result.stdout : result.stderr)
            .split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(result.status)"
        return String(text.prefix(140))
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
