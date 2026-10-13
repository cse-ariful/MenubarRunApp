import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon, even when launched via `swift run`.
        NSApp.setActivationPolicy(.accessory)
        // Load the login-shell environment (PATH, JAVA_HOME, ANDROID_HOME…) off the main thread.
        DispatchQueue.global(qos: .userInitiated).async { _ = Shell.userEnvironment }
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

    private var isBusy: Bool { runner.runningCount > 0 }

    var body: some View {
        Image(nsImage: isBusy ? MenuBarIcon.spinnerImage(frame: frame)
                              : MenuBarIcon.image(for: runner.aggregatePhase))
            .onReceive(ticker) { _ in
                if isBusy { frame = (frame + 1) % MenuBarIcon.spinnerFrameCount }
            }
    }
}
