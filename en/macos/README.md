# macOS — English edition

Latest changes: notifications hide after 15 seconds while automatic task opening keeps its own timer. The expanded card has tighter spacing with unchanged text and button sizes. The application icon is included in the build.

To update, quit the running edition, rebuild, and replace the previous app with the result from `build`. Existing settings are stored separately and retained. Recheck Accessibility permission after replacing the app if you use quick replies.

Requires macOS 13 or newer, Xcode, and its command-line tools.

## Build and run

Open Terminal in this folder and run:

```bash
bash Build.command
```

The script builds Apple Silicon and Intel binaries, combines them into a universal app, includes the icon, applies an ad-hoc signature, and runs 22 core checks. Find the result at `build/Codex Notifier.app`, move it to Applications, and open it. This local build is not notarized for third-party distribution.

Quit the Russian edition before switching. Both use the same application identity and preferences. On first launch, select your preferences and save them. Open settings later from the menu bar icon.

For quick replies, grant the app permission in **System Settings → Privacy & Security → Accessibility**. Login startup uses macOS Login Items; move the app to its permanent location before enabling it.

## Check on your Mac

After the build checks pass, verify appearance, small/large notifications, dismissal, and settings persistence. Test completion detection on a harmless local Codex task. Try insertion first, then immediate sending if desired. Automatic opening and sound depend on your settings and system permissions.

The native AppKit/SwiftUI app uses filesystem events to watch local sessions. Settings are stored at `~/Library/Application Support/CodexNotifier/settings.json`. No Electron runtime or separate server is needed.

[Features, screenshots, and limitations](../README.md)
