import Foundation

enum AndroidError: LocalizedError {
    case sdkNotFound
    case emulatorTimeout(String)

    var errorDescription: String? {
        switch self {
        case .sdkNotFound:
            return "Android SDK not found. Install Android Studio, or set ANDROID_HOME in your shell profile."
        case let .emulatorTimeout(name):
            return "Emulator \(name) didn't finish booting in time."
        }
    }
}

/// Android SDK tools (adb, emulator) and device discovery.
enum AndroidSDK {
    static var home: String? {
        let env = Shell.environment
        guard let path = env["ANDROID_HOME"] ?? env["ANDROID_SDK_ROOT"],
              FileManager.default.fileExists(atPath: path) else { return nil }
        return path
    }

    static var adb: String? { tool("platform-tools/adb", fallback: "adb") }
    static var emulator: String? { tool("emulator/emulator", fallback: "emulator") }

    private static func tool(_ relative: String, fallback: String) -> String? {
        if let home {
            let path = (home as NSString).appendingPathComponent(relative)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return Shell.which(fallback)
    }

    // MARK: - Discovery

    /// Online devices/emulators from `adb devices -l`, plus AVDs that aren't running.
    static func fetchDevices() async -> [Simulator] {
        var result: [Simulator] = []
        var runningAVDs: Set<String> = []

        if let adb, let output = try? await Shell.run(adb, ["devices", "-l"]) {
            for line in output.stdout.split(whereSeparator: \.isNewline).dropFirst() {
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard parts.count >= 2 else { continue }
                let serial = parts[0]
                let state = parts[1]
                let model = parts.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) }

                if serial.hasPrefix("emulator-") {
                    guard state == "device" else { continue }
                    let avd = await avdName(serial: serial, adb: adb) ?? serial
                    runningAVDs.insert(avd)
                    result.append(Simulator(
                        udid: "avd:\(avd)", name: avd.replacingOccurrences(of: "_", with: " "),
                        state: "Booted", runtimeIdentifier: "android", platform: "Android", version: "",
                        kind: .androidEmulator, serial: serial, avdName: avd
                    ))
                } else {
                    // Wireless debugging serials look like "192.168.1.5:5555" or "adb-XXXX._adb-tls-connect._tcp".
                    let wireless = serial.contains(":") || serial.contains("._adb-tls-connect")
                    let online = state == "device"
                    result.append(Simulator(
                        udid: serial,
                        name: (model ?? serial).replacingOccurrences(of: "_", with: " "),
                        state: online ? "Connected" : "Offline",
                        runtimeIdentifier: "android", platform: "Android", version: "",
                        kind: .androidDevice,
                        transport: online ? (wireless ? "Wi-Fi" : "USB") : nil,
                        serial: online ? serial : nil
                    ))
                }
            }
        }

        if let emulator, let output = try? await Shell.run(emulator, ["-list-avds"]) {
            for line in output.stdout.split(whereSeparator: \.isNewline) {
                let avd = line.trimmingCharacters(in: .whitespaces)
                guard !avd.isEmpty, !avd.hasPrefix("INFO"), !avd.contains(" "), !runningAVDs.contains(avd) else { continue }
                result.append(Simulator(
                    udid: "avd:\(avd)", name: avd.replacingOccurrences(of: "_", with: " "),
                    state: "Shutdown", runtimeIdentifier: "android", platform: "Android", version: "",
                    kind: .androidEmulator, avdName: avd
                ))
            }
        }

        // Physical devices first, then running emulators, then the rest.
        return result.sorted { lhs, rhs in
            func rank(_ d: Simulator) -> Int { d.kind == .androidDevice ? (d.isOffline ? 2 : 0) : (d.isBooted ? 1 : 3) }
            if rank(lhs) != rank(rhs) { return rank(lhs) < rank(rhs) }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func avdName(serial: String, adb: String) async -> String? {
        guard let output = try? await Shell.run(adb, ["-s", serial, "emu", "avd", "name"]) else { return nil }
        let name = output.stdout.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return (name?.isEmpty == false && name != "OK") ? name : nil
    }

    // MARK: - Emulator control

    /// Starts an AVD (detached; it keeps running after this app quits).
    static func startEmulator(_ avd: String) throws {
        guard let emulator else { throw AndroidError.sdkNotFound }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: emulator)
        process.arguments = ["-avd", avd]
        process.environment = Shell.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    /// Waits until the AVD shows up in adb and has finished booting; returns its serial.
    static func waitForEmulator(_ avd: String, timeout: TimeInterval = 240) async throws -> String {
        guard let adb else { throw AndroidError.sdkNotFound }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let output = try? await Shell.run(adb, ["devices"]) {
                let serials = output.stdout.split(whereSeparator: \.isNewline)
                    .map { $0.split(separator: "\t").map(String.init) }
                    .filter { $0.count == 2 && $0[0].hasPrefix("emulator-") && $0[1] == "device" }
                    .map { $0[0] }
                for serial in serials {
                    guard await avdName(serial: serial, adb: adb) == avd else { continue }
                    let boot = try? await Shell.run(adb, ["-s", serial, "shell", "getprop", "sys.boot_completed"])
                    if boot?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                        return serial
                    }
                }
            }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw AndroidError.emulatorTimeout(avd)
    }

    static func stopEmulator(serial: String) async throws {
        guard let adb else { throw AndroidError.sdkNotFound }
        try await Shell.checked(adb, ["-s", serial, "emu", "kill"])
    }

    /// Returns a serial for the destination, starting the emulator first if needed.
    static func ensureOnline(_ destination: Simulator) async throws -> String {
        if let serial = destination.serial { return serial }
        guard destination.kind == .androidEmulator, let avd = destination.avdName else {
            throw ShellError.failed(command: "adb", status: 1,
                                    output: "\(destination.name) is offline. Reconnect it or re-pair wireless debugging.")
        }
        try startEmulator(avd)
        return try await waitForEmulator(avd)
    }
}
