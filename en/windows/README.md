# Windows — English edition

## Build and run

Requires Windows with .NET Framework 4.x and WPF. In PowerShell, open this folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
.\CodexNotifier.exe
```

This builds a portable executable, without an installer. On first launch, choose your preferences and click **Save and start**. Open settings again by double-clicking the tray icon, or right-clicking it and selecting **Settings…**.

Quit the Russian edition before starting the English edition. Both use the same settings. If launch at login is enabled, disable it before moving the executable and enable it again from its new location.

## Verification

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1
```

Runs 24 core checks and 28 settings/UI checks. The UI checks briefly open test windows and use focus, so leave the keyboard and mouse idle until they finish. Results and English screenshots are written to `build/verification`.

Settings: `%LOCALAPPDATA%\CodexNotifier\settings.json`. Diagnostic events: `%LOCALAPPDATA%\CodexNotifier\events.log`. The app watches `%USERPROFILE%\.codex\sessions` and reads new log entries using filesystem notifications.

[Features, screenshots, and limitations](../README.md)
