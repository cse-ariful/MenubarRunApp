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
        /// A web app with a dev server (package.json scripts, Django, Rails, Laravel).
        case web
    }

    /// Xcode: the .xcworkspace/.xcodeproj. Flutter/Android/Web: the project root folder.
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
        case .web: return "Web"
        }
    }

    var symbolName: String {
        switch kind {
        case .workspace: return "square.stack.3d.up.fill"
        case .project: return "hammer.fill"
        case .flutter: return "bird.fill"
        case .android: return "cube.fill"
        case .web: return "globe"
        }
    }

    /// Whether this project can run on the given destination.
    func supports(_ destination: Simulator) -> Bool {
        switch kind {
        case .workspace, .project: return destination.isApple
        case .android: return destination.isAndroid
        case .flutter: return destination.kind != .simulator || destination.platform == "iOS" || destination.platform == "iPadOS"
        case .web: return false  // runs a local dev server, no device
        }
    }

    var unsupportedDestinationHint: String {
        switch kind {
        case .workspace, .project: return "Select an Apple simulator or device"
        case .android: return "Select an Android emulator or device"
        case .flutter: return "Select an iOS simulator, a device or an Android emulator"
        case .web: return "Web projects run a local dev server"
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
    /// Launched and attached to the app's console: its output streams into the log until it exits or Stop.
    case streaming
    case succeeded
    /// A tool job (clean, pub get, tests…) finished; the text says what.
    case finished(String)
    case failed(String)
    case cancelled

    var isActive: Bool {
        switch self {
        case .building, .preparing, .booting, .installing, .launching, .attached, .streaming:
            return true
        default:
            return false
        }
    }

    /// Active and not yet launched (drives the menu bar spinner).
    var isBuilding: Bool { isActive && self != .streaming }

    var title: String {
        switch self {
        case .idle: return "Ready"
        case .building: return "Building…"
        case .preparing: return "Locating app…"
        case .booting: return "Starting device…"
        case .installing: return "Installing…"
        case .launching: return "Launching…"
        case .attached: return "Running · hot reload ready"
        case .streaming: return "Running · live logs"
        case .succeeded: return "Running"
        case let .finished(text): return text
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }

    var menuBarSymbol: String {
        switch self {
        case .idle, .cancelled, .finished: return "play.square"
        case .succeeded, .streaming: return "play.square.fill"
        case .failed: return "exclamationmark.triangle"
        default: return "hourglass"
        }
    }
}

// MARK: - Run options

enum FlutterMode: String, Codable, CaseIterable, Identifiable {
    case debug, profile, release
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// Per-project settings that change how Run builds and launches the app.
struct RunOptions: Codable, Equatable {
    // Flutter
    var flutterMode: FlutterMode = .debug
    /// `--flavor`
    var flutterFlavor = ""
    /// `-t`, e.g. lib/main_dev.dart (empty: lib/main.dart)
    var flutterTarget = ""
    /// One KEY=VALUE per line, passed as `--dart-define`.
    var dartDefines = ""

    // Xcode
    /// Build configuration override (empty: the scheme's Run configuration).
    var configuration = ""
    /// Launch arguments, shell-style ("quoted words" stay together).
    var launchArguments = ""
    /// One KEY=VALUE per line, passed to the app's environment.
    var environment = ""
    /// "latitude, longitude" for Simulator ▸ Location ▸ Custom.
    var customLocation = ""

    // Android
    /// Gradle build variant, e.g. "freeDebug" (empty: debug).
    var androidVariant = ""
    /// Ports for `adb reverse`, e.g. "8081 3000".
    var reversePorts = ""

    // Web
    /// Dev server command (empty: the detected one, e.g. "pnpm dev").
    var webCommand = ""
    /// Open the dev server's URL in the browser once it prints one.
    var openBrowserWhenReady = true

    init() {}

    // Tolerate settings saved by older/newer versions (missing keys keep their defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        flutterMode = (try? c.decode(FlutterMode.self, forKey: .flutterMode)) ?? .debug
        flutterFlavor = (try? c.decode(String.self, forKey: .flutterFlavor)) ?? ""
        flutterTarget = (try? c.decode(String.self, forKey: .flutterTarget)) ?? ""
        dartDefines = (try? c.decode(String.self, forKey: .dartDefines)) ?? ""
        configuration = (try? c.decode(String.self, forKey: .configuration)) ?? ""
        launchArguments = (try? c.decode(String.self, forKey: .launchArguments)) ?? ""
        environment = (try? c.decode(String.self, forKey: .environment)) ?? ""
        customLocation = (try? c.decode(String.self, forKey: .customLocation)) ?? ""
        androidVariant = (try? c.decode(String.self, forKey: .androidVariant)) ?? ""
        reversePorts = (try? c.decode(String.self, forKey: .reversePorts)) ?? ""
        webCommand = (try? c.decode(String.self, forKey: .webCommand)) ?? ""
        openBrowserWhenReady = (try? c.decode(Bool.self, forKey: .openBrowserWhenReady)) ?? true
    }

    // MARK: Parsed values

    var dartDefinePairs: [String] { Self.lines(dartDefines).filter { $0.contains("=") } }

    var launchArgumentList: [String] { Self.splitArguments(launchArguments) }

    var environmentPairs: [String: String] {
        var result: [String: String] = [:]
        for line in Self.lines(environment) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = String(line[line.index(after: eq)...]) }
        }
        return result
    }

    var ports: [Int] {
        reversePorts.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Int($0) }.filter { $0 > 0 && $0 < 65536 }
    }

    /// "37.33, -122.01" → (37.33, -122.01)
    var customCoordinate: (Double, Double)? {
        let parts = customLocation.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
              abs(lat) <= 90, abs(lon) <= 180 else { return nil }
        return (lat, lon)
    }

    /// Gradle variant with a capital first letter ("freeDebug" → "FreeDebug"); "Debug" by default.
    var gradleVariant: String {
        let trimmed = androidVariant.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "Debug" }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// Short suffix for the Run button when something non-default is set.
    func runSuffix(for project: XcodeProject) -> String? {
        var parts: [String] = []
        switch project.kind {
        case .flutter:
            if flutterMode != .debug { parts.append(flutterMode.title) }
            if !flutterFlavor.isEmpty { parts.append(flutterFlavor) }
        case .workspace, .project:
            if !configuration.isEmpty { parts.append(configuration) }
        case .android:
            if !androidVariant.isEmpty { parts.append(androidVariant) }
        case .web:
            break
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Shell-like split: spaces separate, quotes group, backslash escapes.
    static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character? = nil
        var escaped = false
        var inToken = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                inToken = true
                continue
            }
            if let q = quote {
                if character == q { quote = nil } else { current.append(character) }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                inToken = true
            } else if character.isWhitespace {
                if inToken { result.append(current) }
                current = ""
                inToken = false
            } else {
                current.append(character)
                inToken = true
            }
        }
        if inToken { result.append(current) }
        return result
    }
}

/// Bundle / application IDs seen on the last successful run, so tools work before the next run.
enum KnownAppIDs {
    private static let key = "knownAppIdentifiers"

    static func get(_ projectID: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[projectID]
    }

    static func set(_ identifier: String, for projectID: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        all[projectID] = identifier
        UserDefaults.standard.set(all, forKey: key)
    }
}

enum Defaults {
    static let selectedSimulator = "selectedSimulatorUDID"
    static let trackedFolders = "trackedFolders"
    static let selectedProject = "selectedProjectPath"
    static let selectedSchemes = "selectedSchemes"
    static let projectLastUsed = "projectLastUsed"
    static let archivedProjects = "archivedProjects"
    static let removedProjects = "removedProjects"
    static let projectDestinations = "projectDestinations"
    static let runOptions = "runOptions"
}

extension String {
    var abbreviatingWithTilde: String { (self as NSString).abbreviatingWithTildeInPath }
}
