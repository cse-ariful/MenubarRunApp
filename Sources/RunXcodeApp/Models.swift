import Foundation

/// A run destination: an iOS/tvOS/watchOS/visionOS simulator, a physical Apple device,
/// an Android emulator (AVD) or a physical Android device.
struct Simulator: Identifiable, Hashable {
    enum Kind: Hashable {
        case simulator
        case device
        case androidEmulator
        case androidDevice
    }

    /// Stable identifier. Simulators/Apple devices: UDID. Android devices: adb serial. Emulators: "avd:<name>".
    let udid: String
    let name: String
    let state: String
    let runtimeIdentifier: String
    let platform: String
    let version: String
    var kind: Kind = .simulator
    /// "USB" / "Wi-Fi" for physical devices.
    var transport: String? = nil
    /// Android: the adb serial when the device/emulator is online (e.g. "emulator-5554").
    var serial: String? = nil
    /// Android emulator: AVD name.
    var avdName: String? = nil

    var id: String { udid }
    var isAndroid: Bool { kind == .androidEmulator || kind == .androidDevice }
    var isApple: Bool { !isAndroid }
    var isPhysical: Bool { kind == .device || kind == .androidDevice }
    var isOffline: Bool { isPhysical && state == "Offline" }
    /// Simulators/emulators: running. Devices: reachable.
    var isBooted: Bool {
        switch kind {
        case .simulator: return state == "Booted" || state == "Booting"
        case .androidEmulator: return serial != nil
        case .device, .androidDevice: return !isOffline
        }
    }
    var runtimeName: String { version.isEmpty ? platform : "\(platform) \(version)" }
    /// Human-readable power state for simulators/emulators.
    var stateLabel: String {
        switch state {
        case "Booted": return "Booted"
        case "Booting": return "Booting…"
        case "Shutting Down": return "Shutting down…"
        default: return isBooted ? "Running" : "Shut down"
        }
    }
    var menuTitle: String {
        if isPhysical {
            return isOffline ? "\(name)  (offline)" : "\(name)  (\(transport ?? "device"))"
        }
        return isBooted ? "\(name)  ●" : name
    }
}

struct RuntimeGroup: Identifiable, Hashable {
    let id: String
    let platform: String
    let version: String
    let simulators: [Simulator]

    var name: String { version.isEmpty ? platform : "\(platform) \(version)" }
}

/// A runnable project found in a tracked folder: Xcode workspace/project, Flutter app or Android (Gradle) app.
struct XcodeProject: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case workspace
        case project
        case flutter
        case android
    }

    /// Xcode: the .xcworkspace/.xcodeproj. Flutter/Android: the project root folder.
    let url: URL
    let kind: Kind
    /// Android: the Gradle module that applies com.android.application (usually "app").
    var androidModule: String? = nil

    var id: String { url.path }
    var isXcode: Bool { kind == .workspace || kind == .project }
    var name: String { isXcode ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent }
    var displayName: String { url.lastPathComponent }
    /// Folder the build runs in.
    var directory: URL { isXcode ? url.deletingLastPathComponent() : url }
    var containerFlag: String { kind == .workspace ? "-workspace" : "-project" }

    var kindLabel: String {
        switch kind {
        case .workspace, .project: return "Xcode"
        case .flutter: return "Flutter"
        case .android: return "Android"
        }
    }

    var symbolName: String {
        switch kind {
        case .workspace: return "square.stack.3d.up.fill"
        case .project: return "hammer.fill"
        case .flutter: return "bird.fill"
        case .android: return "cube.fill"
        }
    }

    /// Whether this project can run on the given destination.
    func supports(_ destination: Simulator) -> Bool {
        switch kind {
        case .workspace, .project: return destination.isApple
        case .android: return destination.isAndroid
        case .flutter: return destination.kind != .simulator || destination.platform == "iOS" || destination.platform == "iPadOS"
        }
    }

    var unsupportedDestinationHint: String {
        switch kind {
        case .workspace, .project: return "Select an Apple simulator or device"
        case .android: return "Select an Android emulator or device"
        case .flutter: return "Select an iOS simulator, a device or an Android emulator"
        }
    }
}

enum RunPhase: Equatable {
    case idle
    case building
    case preparing
    case booting
    case installing
    case launching
    /// Flutter: `flutter run` is attached to the app (hot reload available).
    case attached
    case succeeded
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .building, .preparing, .booting, .installing, .launching, .attached:
            return true
        default:
            return false
        }
    }

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .building: return "Building…"
        case .preparing: return "Locating app…"
        case .booting: return "Starting device…"
        case .installing: return "Installing…"
        case .launching: return "Launching…"
        case .attached: return "Running · hot reload ready"
        case .succeeded: return "Running"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .idle, .cancelled: return "play.square"
        case .succeeded: return "play.square.fill"
        case .failed: return "exclamationmark.triangle"
        default: return "hourglass"
        }
    }
}

enum Defaults {
    static let selectedSimulator = "selectedSimulatorUDID"
    static let trackedFolders = "trackedFolders"
    static let selectedProject = "selectedProjectPath"
    static let selectedSchemes = "selectedSchemes"
    static let projectOrder = "projectOrder"
    static let archivedProjects = "archivedProjects"
    static let removedProjects = "removedProjects"
    static let projectDestinations = "projectDestinations"
}

extension String {
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}
