# RunXcodeApp

A macOS menu bar app that builds and runs your **Xcode**, **Flutter** and **Android** projects on a simulator, emulator or device you pick, without opening Xcode or Android Studio.

## Layout

The popup, top to bottom. The device, project and git rows open **drill-in pages**: the popup is replaced by that row at the top with a search field (already focused) and its full list below. The tapped row glides to the top while the popup keeps its height, so nothing jumps. Click the row again (⌃) or press Esc to go back; picking an item goes back too. Closing the popup always returns to the main view.

1. **Target device** of the selected project. Click it to open the **devices page**: a searchable list (by name or runtime) of only the devices that project type supports (Apple targets for Xcode, Android for Android, both for Flutter), grouped by runtime, with ✓ on the current one and a green dot on running simulators. Return picks the first match. Each project remembers its own choice. A **Running** section at the top shuts down any running simulator, or all of them. **Boot** / **Shut Down** on the row acts on the selected simulator using its live state.
   - Right under the device: **Run on <device>** (⌘R) or **Stop** (⌘.), plus **Hot Reload** (⌘R) and hot restart (⇧⌘R) for Flutter, and the run status line (click it to open the logs).
2. **Project picker.** The selected project. Click it to open the **projects page**: a searchable list (by name, type or path) of the other projects (the selected one is already the header row) with the most recently used first, and the **Archived** section at the bottom (archived matches always show while searching). An **Add Folder…** row stays pinned under the list. Return picks the first match. For Xcode projects, the selected project's row has a compact **scheme picker** on the right, centred on the row (what Run builds; long scheme names are shortened, with the full name in the tooltip). Its menu ends with **Refresh Schemes**; if no schemes were found, the pill says "No schemes" and the menu only offers Refresh Schemes. Rows show a run badge (⏳ building, ⚡ hot reload ready, ✓ launched, ✗ failed), because **several projects can run at the same time**.
3. **Actions** for the selected project:
   - **Logs** opens a **log window** for the project (one per project) with the live build log. After launch, the log keeps going with the **app's own output** (the row shows a green ⦿ and "Running · live logs"):
     - **Filter bar** at the top: every word you type must appear in a line, so you can filter by a tag, a subsystem or any text. `-word` hides lines containing it, and `"quoted phrases"` stay together. Matches are highlighted. **Aa** matches case, and **.\*** switches to a regular expression.
     - **Level:** All, Errors & Warnings, or Errors (understands Xcode, Gradle and logcat `E/` / `W/` lines).
     - **Follow** keeps scrolling to the newest line; turn it off to read back while output keeps coming. Also **Copy** (the lines shown), **Clear** (the window only; the log file is kept), **Open the full log file**, and ⌘F to find. The status bar shows the run state, error and warning counts, and "Showing N of M lines". The window keeps the last 5,000 lines; the log file has everything.
     - **Simulator:** `xcrun simctl launch --console-pty`. You see `print`, `NSLog`, and `os_log` / `Logger` messages, like Xcode's console. **Stop** quits the app.
     - **iPhone / iPad:** `xcrun devicectl device process launch --console`. **Stop** detaches; the app keeps running on the device.
     - **Android:** `adb logcat --pid=<app pid>`. **Stop** force-stops the app.
     - **Run Again** (⌘R) rebuilds and relaunches. If your Xcode's tools don't support attaching to the console, the app is launched as before, without live logs. The menu bar spinner only spins while building, not while logs stream.
   - **Screenshot**, which saves the target device's screen to the **Desktop** and copies it to the clipboard. It uses Xcode's own tools: `xcrun simctl io <udid> screenshot <file>` for simulators, and `xcrun devicectl device screenshot --device <udid> <file>` for **physical iPhones and iPads** (USB or Wi-Fi). Android emulators and phones use `adb`. Nothing extra to install. The first time, allow RunXcodeApp to access the Desktop folder if macOS asks. If saving is blocked, the error offers **Open Privacy Settings**. Messages have an ✕ and clear when the popup closes.
   - **Browse Files** opens a window with the project's folder tree on the left (lazy-loaded; build output, `.git`, `DerivedData`, `node_modules`, `.dart_tool` and similar are hidden) and the selected file on the right:
     - Xcode-style syntax highlighting with line numbers for Swift, Objective-C/C/C++, Kotlin, Java, Gradle, Dart, JavaScript/TypeScript, Python, Ruby (Podfile, Fastfile), shell, JSON, YAML, XML/plist/storyboards, Markdown, `.pbxproj` and `.xcconfig`. Colours follow light and dark mode.
     - **Markdown** files open rendered (headings, lists and task lists, tables, quotes, code blocks, links and local images). A **Preview | Code** switch in the header shows the highlighted source instead; your choice is remembered.
     - **Filter files by name** searches the whole tree. **⌘F** opens the find bar in the file. Images are previewed, and binary plists are shown as XML.
     - Buttons to open the file in its default app or reveal it in Finder. Files over 5 MB aren't previewed, and very long files are shown without colours.
   - **Open in Xcode / Android Studio / VS Code**, **Reveal in Finder**, **Open in Terminal**
   - **Open Log File**
   - **Git** appears at the top of the section when the project is in a git repository. It's a full-width **branch row** (`⎇ develop · up to date with origin/develop · 10 changed  ›`). Click it to open the **git page**.
     - While the status loads, the row shows a spinner and "Reading branch, changes and remotes…" in the same space, so nothing below it jumps. Folders outside a git repository show a dimmed "No git repository" row.
     - The git page has action buttons: **Pull** (`git pull --ff-only`, never creates a merge commit), **Push** (`git push`, or `git push -u origin <branch>` the first time), **Fetch** (`git fetch --all --prune`), **Commit**, **New Branch** (from the current branch, `git switch -c`) and **Refresh**.
     - **Push asks first:** it shows "Push 3 commits to origin/main?" with the commit list, and nothing is sent until you press **Push**.
     - **Commit** (also a **Commit N Changes…** button under the branch row whenever there are changes) opens a window: changed files with checkboxes on the left, the selected file's diff on the right, and a message box. Only the checked files are committed (⌘↩); anything else you had staged stays staged.
     - Below the actions, a search field and the branches: **Local Branches** (✓ marks the current one; click another to switch to it) and **Remote Branches**, grouped by remote (click one to check it out with `git switch --track`).
     - **No password prompts:** git never stops to ask for a password. HTTPS uses your Keychain, SSH uses your loaded keys (`ssh-add --apple-use-keychain`), and missing credentials show an error instead of hanging.
4. **Add Folder…** Its ⋯ menu has tracked folders, removed projects and Launch at Login.
5. **Quit RunXcodeApp** (⌘Q).

**Organizing projects:**

- **Last used first:** the list sorts itself, so the project you most recently selected or ran is at the top. There's no manual reordering.
- **Archive:** choose Archive from a row's ⋯ menu or right-click menu. Archived projects move to the **Archived** section at the bottom of the list, which is collapsed by default; click its header to expand it.
- **Remove:** Remove from List hides a project. To bring it back, open the ⋯ menu on the Add Folder row and go to **Removed Projects**.
- **Saved:** last-used order, archived projects and removed projects are all remembered across restarts.

The row menu also has Open in Xcode / Android Studio / VS Code and Reveal in Finder.

**Dock:** while a commit, file browser or log window is open, RunXcodeApp shows in the Dock and the ⌘-Tab switcher so you can get back to it. When the last window closes, it goes back to menu bar only.

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
- **Log window.** Live build and app output per project, with a text/tag filter and error and warning counts. The full log of each project's last run is saved in `~/Library/Logs/RunXcodeApp/`.
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
2. `xcodebuild -workspace|-project … -scheme <selected> -configuration <scheme's Run configuration> -destination id=<udid> build`. The configuration (for example `Debug-Staging`) and the launched target come from the scheme's `.xcscheme` file, the same as pressing ▶ in Xcode; if the file can't be found, `Debug` is used. The log's first lines show which scheme and configuration were used.
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
| `PopupPages.swift` | Drill-in pages: devices and projects, with search; shared page pieces |
| `GitViews.swift` | Git model, branch row and git page |
| `FileBrowserWindow.swift` | Project file browser: file tree, filter, code view with line numbers |
| `LogWindow.swift` | Log window: filter bar, level filter, follow, live text view |
| `MarkdownPreview.swift` | Rendered Markdown for the file browser |
| `DockPresence.swift` | Shows the Dock icon while an app window is open |
| `SyntaxHighlighter.swift` | Syntax colouring for the file browser |
| `Git.swift` | Git status, fetch/pull/push, switching and creating branches, diffs and commits |
| `CommitWindow.swift` | Commit window: file picker, diff view, message |
| `DeviceTools.swift` | Screenshots; opening a project in Xcode, Android Studio, VS Code or Terminal |
| `AndroidSDK.swift` | adb and emulator discovery; starting and stopping emulators |
| `Shell.swift` | Process helpers (buffered and streaming) |
