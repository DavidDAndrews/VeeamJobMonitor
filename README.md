# Veeam Monitor

A native macOS app (SwiftUI) for watching and controlling backup jobs on a Veeam Backup & Replication server through its REST API (port 9419). The splash screen calls it "Veeam Monitor V13"; the repo includes the Veeam v13 REST API reference used to build it.

## Features

- Sign in with server URL, optional friendly name, username and password; MFA codes and VBR token login are supported for MFA-enabled accounts
- Saved connections (credentials in the macOS Keychain) and a server reachability check
- Jobs list with search, status filters and an All / Backup / Copy scope switch; per-job detail view with recent run log messages and restore points
- Job actions: Start, Start Active Full, Stop, Retry, Enable, Disable; Refresh Jobs (Cmd-R)
- Standalone HTML backup report, written to `~/Downloads` as `VeeamBackup - <server>.html` and opened in the browser
- Light/dark mode and adjustable text size; Liquid Glass styling on macOS 26 and later
- TLS: trust-on-first-use certificate pinning. The server's leaf-certificate SHA-256 is stored in the Keychain on first connection, and later connections are refused if it changes.

The app negotiates the REST API version, preferring `1.3-rev1` with `1.2-rev0` as a fallback (`VeeamAPIService.swift`).

## Requirements

- macOS 14.6 or later (deployment target)
- Xcode to build (Swift 5 language mode); the project was last updated with Xcode 26.5 recommended settings
- A reachable Veeam Backup & Replication REST API endpoint on port 9419

## Build and run

Open `VeeamMonitor.xcodeproj` in Xcode and run the `VeeamMonitor` scheme, or build from the command line:

```bash
xcodebuild -project VeeamMonitor.xcodeproj -scheme VeeamMonitor build
```

The built app is `Veeam Monitor.app`. Known issue (2026-10-04): the `VeeamMonitorTests` target's `TEST_HOST` points at `VeeamMonitor.app`, so `xcodebuild ... test` stops with "Could not find test host" until that setting is updated to match the app's product name.

The app is sandboxed (network client, Downloads and user-selected file access). Bundle ID `bz.andrews.VeeamMonitor`, version 1.3.

## Layout

- `VeeamMonitor/` - app entry point (`VeeamMonitorApp.swift`), `Info.plist`, entitlements and assets
- `VeeamAPIService*.swift`, `VeeamAPIDTOs.swift`, `VeeamModels.swift` - REST client, authentication and data models
- `JobsListView.swift`, `JobDetailView.swift`, `JobRowView.swift`, `JobsToolbar.swift`, `StatusFilterBar.swift`, `LoginView.swift`, `SidebarLayoutController.swift` - UI
- `HTMLReportGenerator.swift`, `ReportExportCoordinator.swift` - HTML report
- `CertificateTrustStore.swift`, `ServerReachability.swift` - TLS pinning and connectivity checks
- `DesignTokens.swift`, `LiquidGlass.swift`, `Formatters.swift`, `StringFormatting.swift`, `JobResultClassification.swift`, `JobRuntimeEstimation.swift` - shared helpers
- `Tests/VeeamMonitorTests.swift` - XCTest unit tests (`VeeamMonitorTests` target)
- `Veeam Rest API Spec swagger.json`, `veeam_backup_13_rest_api_reference_map.pdf` - Veeam REST API reference material
