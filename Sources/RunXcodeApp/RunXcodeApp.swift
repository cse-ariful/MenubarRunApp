import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, even when launched via `swift run`.
        NSApp.setActivationPolicy(.accessory)
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

private struct MenuBarLabel: View {
    @ObservedObject var runner: BuildRunner

    var body: some View {
        Image(nsImage: MenuBarIcon.image(for: runner.phase))
    }
}
