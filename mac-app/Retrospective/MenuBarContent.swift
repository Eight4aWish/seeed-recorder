import SwiftUI

struct MenuBarContent: View {
    @EnvironmentObject var devices: DeviceEnumerator

    var body: some View {
        Text("Retrospective")
            .font(.headline)

        Divider()

        Text("Status: Idle")
        Text("Audio inputs: \(devices.audioInputs.count)")
        Text("MIDI sources: \(devices.midiSources.count)")

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Button("Refresh Devices") {
            devices.refresh()
        }
        .keyboardShortcut("r")

        Divider()

        Button("Quit") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
