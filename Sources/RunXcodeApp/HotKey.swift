import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut (Carbon `RegisterEventHotKey`): works in any app, with the popup closed,
/// and needs no Accessibility permission.
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var action: (@MainActor () -> Void)?

    /// Registers `keyCode` + `modifiers` (Carbon flags, e.g. `cmdKey | shiftKey`). Replaces any previous one.
    func register(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        self.action = action
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                GlobalHotKey.shared.fire()
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        let id = EventHotKeyID(signature: OSType(0x5258_4150), id: 1)  // 'RXAP'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            NSLog("RunXcodeApp: couldn't register the global shortcut (status \(status)); another app may be using it.")
        }
    }

    private func fire() {
        Task { @MainActor in self.action?() }
    }
}

/// ⇧⌘R from anywhere: run the last-run project again with its saved device, scheme and Run Options
/// (web: its dev server command). A run that's still going is stopped first.
@MainActor
enum QuickRun {
    static func registerShortcut(projects: ProjectStore, simulators: SimulatorStore, runner: BuildRunner) {
        GlobalHotKey.shared.register(keyCode: kVK_ANSI_R, modifiers: cmdKey | shiftKey) { [weak projects, weak simulators, weak runner] in
            guard let projects, let simulators, let runner else { return }
            rerunLast(projects: projects, simulators: simulators, runner: runner)
        }
    }

    static func rerunLast(projects: ProjectStore, simulators: SimulatorStore, runner: BuildRunner) {
        let id = runner.lastRunProjectID ?? projects.selectedProjectID
        guard let id, let project = projects.projects.first(where: { $0.id == id }) else {
            NSSound.beep()  // nothing has been run yet
            return
        }
        let options = projects.runOptions(for: project)
        let session = runner.session(ensuring: project)

        Task {
            await session.stopAndWait()

            if project.kind == .web {
                let command = WebProject.command(for: project, options: options)
                guard !command.isEmpty else {
                    return problem("Enter the command that starts the dev server", in: session)
                }
                projects.markUsed(project)
                runner.runWeb(project: project, command: command, options: options)
                return
            }

            guard let destination = simulators.destination(for: project, chosen: projects.destinationID(for: project)),
                  project.supports(destination) else {
                return problem(project.unsupportedDestinationHint, in: session)
            }
            if destination.isOffline {
                return problem("\(destination.name) is offline", in: session)
            }
            let scheme = projects.selectedScheme(for: project)
            if project.isXcode, scheme == nil {
                return problem("Select a scheme first", in: session)
            }
            projects.markUsed(project)
            runner.run(project: project, scheme: project.isXcode ? scheme : nil, simulator: destination, options: options)
        }
    }

    /// Can't run: beep, and show why in the popup (and the menu bar icon's ! badge).
    private static func problem(_ text: String, in session: RunSession) {
        NSSound.beep()
        session.reportProblem(text)
    }
}
