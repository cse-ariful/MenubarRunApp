import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, even when launched via `swift run`.
        NSApp.setActivationPolicy(.accessory)
        // Load the login-shell environment (PATH, JAVA_HOME, ANDROID_HOME…) off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { _ = Shell.userEnvironment }
        // SwiftUI may install its own menus after launch; only add ours if there's no Edit menu by then.
        DispatchQueue.main.async { Self.installEditMenuIfNeeded() }
    }

    /// Key equivalents (⌘C, ⌘V, ⌘A, ⌘F…) in the commit and file windows are routed through the main menu,
    /// which a menu bar app doesn't show but still uses.
    private static func installEditMenuIfNeeded() {
        let hasCopy = NSApp.mainMenu?.items.contains { item in
            item.submenu?.items.contains { $0.action == #selector(NSText.copy(_:)) } ?? false
        } ?? false
        guard !hasCopy else { return }

        let main = NSApp.mainMenu ?? NSMenu()
        if main.items.isEmpty {
            let appItem = NSMenuItem()
            let appMenu = NSMenu()
            appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            appMenu.addItem(withTitle: "Quit RunXcodeApp", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            appItem.submenu = appMenu
            main.addItem(appItem)
        }

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let findNext = NSMenuItem(title: "Find Next", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "g")
        findNext.tag = NSTextFinder.Action.nextMatch.rawValue
        edit.addItem(findNext)
        let findPrevious = NSMenuItem(title: "Find Previous", action: #selector(NSTextView.performTextFinderAction(_:)), keyEquivalent: "G")
        findPrevious.tag = NSTextFinder.Action.previousMatch.rawValue
        edit.addItem(findPrevious)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}

@main
struct RunXcodeAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var simulators = SimulatorStore()
    @StateObject private var projects = ProjectStore()
    @StateObject private var runner = BuildRunner()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(simulators)
                .environmentObject(projects)
                .environmentObject(runner)
        } label: {
            MenuBarLabel(runner: runner)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar icon. Spins while any project is building, installing, launching or attached (Flutter).
private struct MenuBarLabel: View {
    @ObservedObject var runner: BuildRunner
    @State private var frame = 0
    private let ticker = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    private var isBusy: Bool { runner.buildingCount > 0 }

    var body: some View {
        Image(nsImage: isBusy ? MenuBarIcon.spinnerImage(frame: frame)
                              : MenuBarIcon.image(for: runner.aggregatePhase))
            .onReceive(ticker) { _ in
                if isBusy { frame = (frame + 1) % MenuBarIcon.spinnerFrameCount }
            }
    }
}
