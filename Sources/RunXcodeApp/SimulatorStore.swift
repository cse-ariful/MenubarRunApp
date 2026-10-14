import AppKit
import Foundation

/// Lists available simulators via `simctl` and keeps their boot state up to date.
@MainActor
final class SimulatorStore: ObservableObject {
    @Published private(set) var groups: [RuntimeGroup] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?

    /// Dismisses the error shown under the device row.
    func clearError() { lastError = nil }
    @Published private(set) var busyUDIDs: Set<String> = []
    @Published var selectedUDID: String? {
        didSet { UserDefaults.standard.set(selectedUDID, forKey: Defaults.selectedSimulator) }
    }

    private var isRefreshing = false
    /// A refresh was requested while one was running; run another right after so results aren't stale.
    private var refreshQueued = false
    /// Physical devices seen this session, so a device dropping off Wi-Fi doesn't reset the selection.
    private var knownDeviceUDIDs: Set<String> = []
    private var timer: Timer?

    init() {
        selectedUDID = UserDefaults.standard.string(forKey: Defaults.selectedSimulator)
        Task { await refresh() }
        // Track boot state changes made elsewhere (Xcode, Simulator.app, the CLI).
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh(silent: true) }
        }
    }

    var allSimulators: [Simulator] { groups.flatMap(\.simulators) }
    var selected: Simulator? { allSimulators.first { $0.udid == selectedUDID } }
    var bootedSimulators: [Simulator] { allSimulators.filter(\.isBooted) }

    /// Destination for a project: its saved choice if still available and compatible, otherwise the
    /// last-used destination if compatible, otherwise a sensible default for the project type.
    func destination(for project: XcodeProject, chosen: String?) -> Simulator? {
        let all = allSimulators
        if let chosen, let match = all.first(where: { $0.udid == chosen }), project.supports(match) { return match }
        if let last = selected, project.supports(last) { return last }
        let compatible = all.filter { project.supports($0) && !$0.isOffline }
        return compatible.first(where: { $0.isBooted && !$0.isPhysical })
            ?? compatible.first(where: { $0.kind == .simulator && $0.platform == "iOS" && $0.name.hasPrefix("iPhone") })
            ?? compatible.first(where: { $0.kind == .androidEmulator })
            ?? compatible.first
    }

    /// Runtime groups filtered to what the project can run on (all groups when `project` is nil).
    func groups(for project: XcodeProject?) -> [RuntimeGroup] {
        guard let project else { return groups }
        return groups.compactMap { group in
            let compatible = group.simulators.filter { project.supports($0) }
            return compatible.isEmpty ? nil
                : RuntimeGroup(id: group.id, platform: group.platform, version: group.version, simulators: compatible)
        }
    }

    func refresh(silent: Bool = false) async {
        if isRefreshing {
            refreshQueued = true
            return
        }
        isRefreshing = true
        if !silent { isLoading = true }
        repeat {
            refreshQueued = false
            await performRefresh()
        } while refreshQueued
        isRefreshing = false
        isLoading = false
    }

    private func performRefresh() async {
        async let simctlResult = Shell.checked(Shell.xcrunPath, ["simctl", "list", "devices", "available", "-j"])
        async let physicalDevices = Self.fetchPhysicalDevices()
        async let androidDevices = AndroidSDK.fetchDevices()

        var parsed: [RuntimeGroup] = []
        var simctlError: String?
        do {
            let simctlOutput = try await simctlResult
            parsed = try Self.parse(simctlOutput.stdout)
        } catch {
            simctlError = "Couldn't list simulators. Is Xcode installed and selected (xcode-select)? \(error.localizedDescription)"
        }

        let android = await androidDevices
        if !android.isEmpty {
            parsed.insert(RuntimeGroup(id: "android", platform: "Android", version: "", simulators: android), at: 0)
            knownDeviceUDIDs.formUnion(android.map(\.udid))
        }
        let devices = await physicalDevices
        if !devices.isEmpty {
            parsed.insert(RuntimeGroup(id: "physical-devices", platform: "Devices", version: "", simulators: devices), at: 0)
            knownDeviceUDIDs.formUnion(devices.map(\.udid))
        }
        if parsed != groups { groups = parsed }
        // Only complain about simctl when there's nothing else to run on.
        lastError = parsed.isEmpty ? simctlError : nil

        let selectionIsKnownDevice = selectedUDID.map { knownDeviceUDIDs.contains($0) } ?? false
        if selected == nil, !selectionIsKnownDevice, !parsed.isEmpty {
            let everything = parsed.flatMap(\.simulators)
            let simulators = everything.filter { $0.kind == .simulator }
            let fallback = simulators.first(where: { $0.isBooted })
                ?? simulators.first(where: { $0.platform == "iOS" && $0.name.hasPrefix("iPhone") })
                ?? simulators.first
                ?? everything.first
            selectedUDID = fallback?.udid
        }
    }

    /// Boots or shuts down based on the simulator's *current* state (re-read from simctl),
    /// not the possibly stale state from the last poll.
    func togglePower(_ simulator: Simulator) async {
        busyUDIDs.insert(simulator.udid)
        let current = simulator.kind == .simulator ? await Self.currentState(udid: simulator.udid) : nil
        busyUDIDs.remove(simulator.udid)

        switch current {
        case "Booted"?, "Booting"?:
            await shutdown(simulator)
        case "Shutdown"?:
            await boot(simulator)
        case .some:
            await refresh(silent: true)  // e.g. "Shutting Down": just update the UI
        case nil:
            if simulator.isBooted { await shutdown(simulator) } else { await boot(simulator) }
        }
    }

    func shutdownAll() async {
        let running = bootedSimulators.filter { $0.kind == .simulator || $0.kind == .androidEmulator }
        busyUDIDs.formUnion(running.map(\.udid))
        do {
            if running.contains(where: { $0.kind == .simulator }) {
                try await Shell.checked(Shell.xcrunPath, ["simctl", "shutdown", "all"])
            }
            for emulator in running where emulator.kind == .androidEmulator {
                if let serial = emulator.serial { try await AndroidSDK.stopEmulator(serial: serial) }
            }
        } catch {
            lastError = error.localizedDescription
        }
        busyUDIDs.subtract(running.map(\.udid))
        await refresh(silent: true)
    }

    nonisolated static func currentState(udid: String) async -> String? {
        guard let result = try? await Shell.run(Shell.xcrunPath, ["simctl", "list", "devices", "-j"]),
              result.succeeded,
              let groups = try? parse(result.stdout) else { return nil }
        return groups.flatMap(\.simulators).first { $0.udid == udid }?.state
    }

    func boot(_ simulator: Simulator) async {
        busyUDIDs.insert(simulator.udid)
        do {
            if simulator.kind == .androidEmulator, let avd = simulator.avdName {
                try AndroidSDK.startEmulator(avd)
                _ = try await AndroidSDK.waitForEmulator(avd)
            } else {
                try await Shell.checked(Shell.xcrunPath, ["simctl", "boot", simulator.udid])
                await Self.openSimulatorApp(udid: simulator.udid)
            }
        } catch {
            lastError = error.localizedDescription
        }
        busyUDIDs.remove(simulator.udid)
        await refresh(silent: true)
    }

    func shutdown(_ simulator: Simulator) async {
        busyUDIDs.insert(simulator.udid)
        do {
            if simulator.kind == .androidEmulator, let serial = simulator.serial {
                try await AndroidSDK.stopEmulator(serial: serial)
            } else {
                try await Shell.checked(Shell.xcrunPath, ["simctl", "shutdown", simulator.udid])
            }
        } catch {
            lastError = error.localizedDescription
        }
        busyUDIDs.remove(simulator.udid)
        await refresh(silent: true)
    }

    static func openSimulatorApp(udid: String?) async {
        var args = ["-a", "Simulator"]
        if let udid { args += ["--args", "-CurrentDeviceUDID", udid] }
        _ = try? await Shell.run("/usr/bin/open", args)
    }

    // MARK: - Physical devices (Xcode 15+: devicectl)

    /// Lists paired iPhones/iPads/etc. connected by USB or Wi-Fi. Returns [] on older Xcode.
    nonisolated static func fetchPhysicalDevices() async -> [Simulator] {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunXcodeApp-devices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        _ = try? await Shell.run(Shell.xcrunPath, ["devicectl", "list", "devices", "--json-output", output.path])
        guard let data = try? Data(contentsOf: output) else { return [] }
        return parsePhysicalDevices(data)
    }

    private struct DeviceCtlList: Decodable {
        struct Result: Decodable { let devices: [Device] }
        struct Device: Decodable {
            let identifier: String
            let deviceProperties: DeviceProperties?
            let hardwareProperties: HardwareProperties?
            let connectionProperties: ConnectionProperties?
        }
        struct DeviceProperties: Decodable {
            let name: String?
            let osVersionNumber: String?
        }
        struct HardwareProperties: Decodable {
            let udid: String?
            let platform: String?
            let marketingName: String?
            let reality: String?
        }
        struct ConnectionProperties: Decodable {
            let transportType: String?
            let tunnelState: String?
            let pairingState: String?
        }

        let result: Result
    }

    nonisolated static func parsePhysicalDevices(_ data: Data) -> [Simulator] {
        guard let list = try? JSONDecoder().decode(DeviceCtlList.self, from: data) else { return [] }
        let devices: [Simulator] = list.result.devices.compactMap { device in
            let hardware = device.hardwareProperties
            let connection = device.connectionProperties
            if let reality = hardware?.reality, reality != "physical" { return nil }
            if let pairing = connection?.pairingState, pairing != "paired" { return nil }

            let transport: String
            switch connection?.transportType {
            case "wired": transport = "USB"
            case "localNetwork": transport = "Wi-Fi"
            default: transport = "Network"
            }
            let offline = connection?.tunnelState == "unavailable"

            var platform = hardware?.platform ?? "iOS"
            if platform == "xrOS" { platform = "visionOS" }

            return Simulator(
                udid: hardware?.udid ?? device.identifier,
                name: device.deviceProperties?.name ?? hardware?.marketingName ?? "Device",
                state: offline ? "Offline" : "Connected",
                runtimeIdentifier: "device",
                platform: platform,
                version: device.deviceProperties?.osVersionNumber ?? "",
                kind: .device,
                transport: offline ? nil : transport
            )
        }
        // Reachable devices first, then offline ones.
        return devices.sorted { lhs, rhs in
            if lhs.isOffline != rhs.isOffline { return !lhs.isOffline }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - Parsing

    private struct SimctlList: Decodable {
        struct Device: Decodable {
            let udid: String
            let name: String
            let state: String
            let isAvailable: Bool?
        }

        let devices: [String: [Device]]
    }

    nonisolated static func parse(_ json: String) throws -> [RuntimeGroup] {
        let list = try JSONDecoder().decode(SimctlList.self, from: Data(json.utf8))
        var groups: [RuntimeGroup] = []

        for (runtimeID, devices) in list.devices {
            let available = devices.filter { $0.isAvailable ?? true }
            guard !available.isEmpty else { continue }
            let (platform, version) = parseRuntime(runtimeID)
            let simulators = available
                .map {
                    Simulator(udid: $0.udid, name: $0.name, state: $0.state,
                              runtimeIdentifier: runtimeID, platform: platform, version: version)
                }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            groups.append(RuntimeGroup(id: runtimeID, platform: platform, version: version, simulators: simulators))
        }

        return groups.sorted { lhs, rhs in
            let lo = platformOrder(lhs.platform), ro = platformOrder(rhs.platform)
            if lo != ro { return lo < ro }
            return lhs.version.compare(rhs.version, options: .numeric) == .orderedDescending
        }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-17-5" -> ("iOS", "17.5")
    nonisolated static func parseRuntime(_ identifier: String) -> (String, String) {
        let tail = identifier.components(separatedBy: "SimRuntime.").last ?? identifier
        var parts = tail.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return (tail, "") }
        var platform = parts.removeFirst()
        if platform == "xrOS" { platform = "visionOS" }
        return (platform, parts.joined(separator: "."))
    }

    nonisolated private static func platformOrder(_ platform: String) -> Int {
        switch platform {
        case "iOS": return 0
        case "iPadOS": return 1
        case "visionOS": return 2
        case "watchOS": return 3
        case "tvOS": return 4
        default: return 5
        }
    }
}
