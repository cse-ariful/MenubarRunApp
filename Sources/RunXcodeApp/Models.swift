import Foundation

/// A run destination: a simulator or a physical device (USB or Wi-Fi).
struct Simulator: Identifiable, Hashable {
    enum Kind: Hashable {
        case simulator
        case device
    }

    let udid: String
    let name: String
    let state: String
    let runtimeIdentifier: String
    let platform: String
    let version: String
    var kind: Kind = .simulator
    /// "USB" / "Wi-Fi" for physical devices.
    var transport: String? = nil

    var id: String { udid }
    var isPhysical: Bool { kind == .device }
    var isOffline: Bool { isPhysical && state == "Offline" }
    /// Simulators: booted. Devices: reachable.
    var isBooted: Bool { isPhysical ? !isOffline : state == "Booted" }
    var runtimeName: String { version.isEmpty ? platform : "\(platform) \(version)" }
    var menuTitle: String {
        guard isPhysical else { return isBooted ? "\(name)  ●" : name }
        return isOffline ? "\(name)  (offline)" : "\(name)  (\(transport ?? "device"))"
    }
}

struct RuntimeGroup: Identifiable, Hashable {
    let id: String
    let platform: String
    let version: String
    let simulators: [Simulator]

    var name: String { version.isEmpty ? platform : "\(platform) \(version)" }
}

struct XcodeProject: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case workspace
        case project
    }

    let url: URL
    let kind: Kind

    var id: String { url.path }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var displayName: String { url.lastPathComponent }
    var directory: URL { url.deletingLastPathComponent() }
    var containerFlag: String { kind == .workspace ? "-workspace" : "-project" }
}

enum RunPhase: Equatable {
    case idle
    case building
    case preparing
    case booting
    case installing
    case launching
    case succeeded
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .building, .preparing, .booting, .installing, .launching:
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
        case .booting: return "Booting simulator…"
        case .installing: return "Installing…"
        case .launching: return "Launching…"
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
}

extension String {
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}
