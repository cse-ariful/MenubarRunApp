# RunXcodeApp

A macOS menu bar app that builds and runs your **Xcode**, **Flutter** and **Android** projects on a simulator, emulator or device you pick, without opening Xcode or Android Studio.

## Layout

The popup, top to bottom:

1. **Target device** of the selected project. Click the name to switch devices. The menu only lists devices that project type supports (Apple targets for Xcode, Android for Android, both for Flutter), and each project remembers its own choice. **Boot** / **Shut Down** acts on that simulator using its live state. The **Running** section in the menu shuts down any running simulator, or all of them.
2. **Project picker.** A single collapsible row showing the selected project. Click it to expand the project list (most recently used first), then click a project to select it; the list collapses again. Rows show a run badge (⏳ building, ⚡ hot reload ready, ✓ launched, ✗ failed), because **several projects can run at the same time**.
3. **Actions** for the selected project:
   - **Run on <device>** (⌘R) or **Stop** (⌘.), plus **Hot Reload** (⌘R) and hot restart (⇧⌘R) for Flutter
   - **Show / Hide Logs**, the live build log for this project
   - **Screenshot**, which saves the target device's screen to the **Desktop** and copies it to the clipboard (the first time, allow RunXcodeApp to access the Desktop folder if macOS asks; you can change this in System Settings › Privacy & Security › Files and Folders). Simulators, Android emulators and Android phones work out of the box. **Physical iPhones** (USB or Wi-Fi) need [pymobiledevice3](https://github.com/doronz88/pymobiledevice3), because Apple doesn't ship a command-line screenshot tool (Xcode uses private frameworks). The app sets this up for you, asking first:
     - **Missing tool:** if it isn't installed, the app offers to **Install** it, running `brew install pipx` and `pipx install pymobiledevice3` (needs Homebrew).
     - **iOS 17+ tunnel:** if the device tunnel isn't running, the app offers to **Open Terminal** with `sudo pymobiledevice3 remote tunneld`. Enter your password there and keep the window open.

     Messages under the buttons have an ✕ to dismiss them, and they clear when the popup closes.
     libimobiledevice's `idevicescreenshot` is also tried if it's installed (mainly works for iOS 16 and earlier).
   - **Open in Xcode / Android Studio / VS Code**, **Reveal in Finder**, **Open in Terminal**
   - **Reload Schemes** (Xcode) or **Open Log File**
   - For Xcode projects, the scheme picker sits in the Actions header.
4. **Add Folder…** Its ⋯ menu has tracked folders, removed projects and Launch at Login.
5. **Quit RunXcodeApp** (⌘Q).

**Organizing projects:**

- **Last used first:** the list sorts itself, so the project you most recently selected or ran is at the top. There's no manual reordering.
- **Archive:** choose Archive from a row's ⋯ menu or right-click menu. Archived projects move to the **Archived** section at the bottom of the list, which is collapsed by default; click its header to expand it.
- **Remove:** Remove from List hides a project. To bring it back, open the ⋯ menu on the Add Folder row and go to **Removed Projects**.
- **Saved:** last-used order, archived projects and removed projects are all remembered across restarts.

The row menu also has Open in Xcode / Android Studio / VS Code and Reveal in Finder.

## Supported projects (auto-detected)

| Type | Detected when | Runs on | How it runs |
| --- | --- | --- | --- |
| Xcode | `.xcworkspace` or `.xcodeproj` (a workspace wins over a project in the same folder) | iOS, tvOS, watchOS and visionOS simulators; Apple devices | `xcodebuild`, then `simctl` or `devicectl` install and launch |
| Flutter | `pubspec.yaml` depends on `sdk: flutter` and `lib/main.dart` exists | iOS simulators, Apple devices, Android emulators and devices | `flutter run -d <device>`. Hot reload ⚡ (⌘R) and hot restart (⇧⌘R) stay available while it runs, and ■ stops it |
| Android | Gradle root (`settings.gradle(.kts)`) with a module applying `com.android.application` | Android emulators and devices (USB or wireless debugging) | `./gradlew :app:installDebug`, then `adb` launches the app |

A Flutter app's `ios/` and `android/` folders aren't listed as separate projects. Flutter packages and plugins (no `lib/main.dart`) are skipped, but their `example/` apps are found. Android emulators that aren't running are listed too, and are started automatically when you press ▶.

**Toolchains:** the app reads `PATH`, `JAVA_HOME` and `ANDROID_HOME` from your login shell, so `flutter`, `adb` and `emulator` resolve the same way they do in Terminal. It falls back to `~/Library/Android/sdk` and Android Studio's bundled JDK.

**Android limitation:** the debug variant is always used. Projects with product flavors (for example `installFreeDebug`) aren't supported yet.

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
./build_app.sh --dmg        # build ./build/RunXcodeApp-<version>.dmg (drag-to-Applications installer)
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
- **Menu bar icon:** drawn in code (`MenuBarIcon.swift`), so it adapts to light and dark menu bars. The badge shows ▶ when ready, an animated spinning ring while any project is building, installing, launching or attached to Flutter, and ! after a failure.

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
   - attaches `RunXcodeApp-1.0.0.dmg` to a GitHub Release
   - writes `Casks/runxcodeapp.rb` into the tap with the new version and checksum

For each later release, commit your changes and run `scripts/release.sh <next version>`.

The cask's source of truth is `packaging/homebrew/runxcodeapp.rb`. Edit it there, and the next release copies it to the tap.

## Releasing a DMG

Releases ship as a **DMG**: a disk image with `RunXcodeApp.app` and an Applications shortcut. Homebrew installs from it, and people can also download it from the GitHub Release page and drag the app into Applications.

- **Build one locally:** `UNIVERSAL=1 VERSION=1.0.0 ./build_app.sh --dmg` creates `build/RunXcodeApp-1.0.0.dmg`.
- **Release from your Mac** (no CI needed): `scripts/manual_release.sh 1.0.0` builds the DMG, creates the GitHub Release with the DMG attached, and updates `Casks/runxcodeapp.rb` in `cse-ariful/homebrew-tap` with the new version and SHA-256.
- **Release from CI:** `scripts/release.sh 1.0.0` pushes a tag, and GitHub Actions does the same steps.

After either one, users install or upgrade with `brew install --cask cse-ariful/tap/runxcodeapp` or `brew upgrade --cask runxcodeapp`.

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
| `BuildRunner.swift` | Build and run pipelines for Xcode, Flutter and Android, plus the log |
| `DeviceTools.swift` | Screenshots; opening a project in Xcode, Android Studio, VS Code or Terminal |
| `AndroidSDK.swift` | adb and emulator discovery; starting and stopping emulators |
| `Shell.swift` | Process helpers (buffered and streaming) |
