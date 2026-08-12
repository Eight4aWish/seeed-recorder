import SwiftUI
import AppKit

struct MenuBarContent: View {
    @EnvironmentObject var devices: DeviceEnumerator
    @EnvironmentObject var engine: AudioCaptureEngine
    @EnvironmentObject var midi: MIDIController
    @EnvironmentObject var coordinator: CaptureCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("Retrospective")
            .font(.headline)

        Divider()

        Text("State: \(coordinator.state.rawValue.capitalized)")

        if engine.isCapturing {
            Text("Capturing: \(engine.channelCount) ch @ \(Int(engine.sampleRate)) Hz")
            Text("Frames/sec: \(Int(engine.framesPerSecond))")
        } else {
            Text("Audio: idle")
        }

        if let r = coordinator.lastResult {
            Text("Last save: \(r.writtenFiles.count) ch (\(r.skippedSilentChannels.count) silent skipped)")
        }
        if let err = coordinator.lastError {
            Text("Error: \(err)").foregroundStyle(.red)
        }

        Divider()

        Button("Capture Now") {
            coordinator.triggerCaptureFromExternal(source: "menu-bar")
        }
        .keyboardShortcut("c")
        .disabled(!engine.isCapturing || coordinator.state != .idle)

        Button("Review Captures…") {
            // LSUIElement apps have no Dock presence, so the window would open
            // behind whatever is frontmost without an explicit activate.
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: RetrospectiveApp.reviewWindowID)
        }
        .keyboardShortcut("l")

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        if let path = engine.scratchPath {
            Button("Reveal Scratch in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        }

        Button("Reveal Captures in Finder") {
            try? FileManager.default.createDirectory(at: coordinator.outputRoot, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([coordinator.outputRoot])
        }

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
