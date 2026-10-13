# RunXcodeApp

A macOS menu bar app that builds an Xcode project and runs it on a simulator you pick, without opening Xcode.

## Layout

The popup is a single list:

1. **Selected simulator.** Click the name to switch devices. The power icon boots or shuts it down.
2. **One row per project.** Each row shows the scheme (click it to change), the path, and a ▶ Run button on the right. While a project is running, its row shows live status and the button turns into ■ Stop.
3. **Add Folder…** is the last row. Its ⋯ menu has the build log, tracked folders, Launch at Login and Quit.

**Organizing projects:**

- **Reorder:** drag a row, or use the row's ⋯ menu (shown on hover) or right-click menu: Move to Top, Move Up, Move Down.
- **Archive:** choose Archive from the row menu, or drag a project onto the **Archived** header. The Archived section sits below your projects and is collapsed by default. Click the header to expand it.
- **Remove:** Remove from List hides a project. To bring it back, open the ⋯ menu on the Add Folder row and go to **Removed Projects**.
- **Saved:** order, archived projects and removed projects are all remembered across restarts.

The row menu also has Open in Xcode, Reveal in Finder and Reload Schemes.

## Features

- **Simulator picker.** Lists every available simulator, grouped by runtime (iOS, iPadOS, visionOS, watchOS, tvOS). Booted devices are marked with ●.
- **Physical devices.** iPhones and iPads paired with Xcode show up in a **Devices** section at the top of the device menu, whether connected by USB or Wi-Fi (this needs Xcode 15 or later, which provides `devicectl`). Runs on a device build with automatic signing (`-allowProvisioningUpdates`), then install and launch with `xcrun devicectl`.
- **Live tracking.** Boot state refreshes every 10 s, so changes made in Xcode or Simulator.app show up here. You can also boot or shut down the selected device from the menu.
- **Project folders.** Add one or more folders. They're scanned for `.xcworkspace` / `.xcodeproj` files (Pods, DerivedData, build folders and similar are skipped). You can also add a project file directly.
- **Scheme picker.** Schemes are read with `xcodebuild -list`. Your last choice is remembered for each project.
- **Run button (per project).** Builds with `xcodebuild` while the simulator boots, then finds the built `.app`, installs it, and launches it (relaunching if it's already running).
- **Stop (⌘.).** Cancels the build.
- **Build log.** Shows live output with error and warning counts. The full log is saved to `~/Library/Logs/RunXcodeApp/last-run.log`.
- **Persistent settings.** Folders, the selected simulator, the selected project and schemes all survive restarts. There's also a **Launch at login** option.

## Requirements

- macOS 13 Ventura or later
- Xcode installed and selected: `sudo xcode-select -s /Applications/Xcode.app`

## Install with Homebrew

```bash
brew install --cask cse-ariful/tap/runxcodeapp
```

To upgrade, run `brew upgrade --cask runxcodeapp`. To uninstall, run `brew uninstall --cask runxcodeapp`, or add `--zap` to also remove its settings and logs.

The app is ad-hoc signed, not notarized. The cask clears macOS's download quarantine after install, so it opens without a Gatekeeper prompt.

## Build & run

```bash
cd RunXcodeApp
./build_app.sh --run        # build ./build/RunXcodeApp.app and launch it
./build_app.sh --install    # build, copy to /Applications, launch
```

You can also open `Package.swift` in Xcode and press Run. The app only appears in the menu bar, not in the Dock.

## How a run works

1. `xcrun simctl bootstatus <udid> -b` boots the simulator, in parallel with step 2.
2. `xcodebuild -workspace|-project … -scheme … -configuration Debug -destination id=<udid> build`
3. `xcodebuild … -showBuildSettings -json` finds `TARGET_BUILD_DIR/FULL_PRODUCT_NAME` for the app target.
4. `xcrun simctl install <udid> <App.app>`
5. `xcrun simctl launch --terminate-running-process <udid> <bundle id>`

Builds use Xcode's normal DerivedData, so they share the incremental build cache with Xcode.

## Icon

- **App icon:** `Support/AppIcon.icns`, an original hammer with a green ▶ run badge. To regenerate it, run `python3 Support/icon/make_icon.py Support` (requires Pillow).
- **Menu bar icon:** drawn in code (`MenuBarIcon.swift`), so it adapts to light and dark menu bars. The badge shows ▶ when ready, ⌛ while working and ! after a failure.

## Publishing to Homebrew (one-time setup)

1. **Push this project** to [cse-ariful/MenubarRunApp](https://github.com/cse-ariful/MenubarRunApp):
   ```bash
   git init && git add . && git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/cse-ariful/MenubarRunApp.git
   git push -u origin main
   ```
2. **Create the tap repo.** It must be public and named `homebrew-tap`:
   ```bash
   gh repo create cse-ariful/homebrew-tap --public --add-readme
   ```
3. **Let the workflow update the tap.** Create a fine-grained personal access token with **Contents: Read and write** on `homebrew-tap`. Save it in the MenubarRunApp repo under Settings → Secrets and variables → Actions as `TAP_GITHUB_TOKEN`.
4. **Release:**
   ```bash
   scripts/release.sh 1.0.0
   ```
   GitHub Actions then:
   - builds a universal (Apple Silicon and Intel) `.app`
   - attaches `RunXcodeApp-1.0.0.zip` to a GitHub Release
   - writes `Casks/runxcodeapp.rb` into the tap with the new version and checksum

For each later release, commit your changes and run `scripts/release.sh <next version>`.

The cask's source of truth is `packaging/homebrew/runxcodeapp.rb`. Edit it there, and the next release copies it to the tap.

## Notes

- The app is not sandboxed, because it needs to run `xcrun`, `xcodebuild` and `simctl`.
- If no schemes are listed, open the project in Xcode once or mark the scheme as **Shared**.

## Files

| File | Purpose |
| --- | --- |
| `RunXcodeApp.swift` | App entry point and `MenuBarExtra` |
| `MenuContentView.swift` | Menu bar popover UI |
| `SimulatorStore.swift` | `simctl` listing, polling, boot and shutdown |
| `ProjectStore.swift` | Tracked folders, project scanning, schemes |
| `BuildRunner.swift` | Build, install and launch pipeline, plus the log |
| `Shell.swift` | Process helpers (buffered and streaming) |
