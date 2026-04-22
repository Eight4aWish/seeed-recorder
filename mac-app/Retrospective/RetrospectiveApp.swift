// Menu-bar-only SwiftUI app. Two scenes:
//   MenuBarExtra — the status-bar icon + its click menu
//   Settings     — a standard Settings window (⌘,)
//
// No Dock icon: Info.plist sets LSUIElement = true.

import SwiftUI

@main
struct RetrospectiveApp: App {
    @StateObject private var devices = DeviceEnumerator()

    var body: some Scene {
        MenuBarExtra("Retrospective", systemImage: "record.circle") {
            MenuBarContent()
                .environmentObject(devices)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(devices)
        }
    }
}
