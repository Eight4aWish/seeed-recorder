// Menu-bar-only SwiftUI app. Two scenes:
//   MenuBarExtra — the status-bar icon + its click menu
//   Settings     — a standard Settings window (⌘,)
//
// No Dock icon: Info.plist sets LSUIElement = true.

import SwiftUI

@main
struct RetrospectiveApp: App {
    @StateObject private var devices = DeviceEnumerator()
    @StateObject private var engine: AudioCaptureEngine
    @StateObject private var midi: MIDIController
    @StateObject private var coordinator: CaptureCoordinator
    @StateObject private var httpServer: HTTPServer

    init() {
        let engine = AudioCaptureEngine()
        let midi = MIDIController()
        let coordinator = CaptureCoordinator(midi: midi, engine: engine)
        let http = HTTPServer(coordinator: coordinator, engine: engine)
        _engine = StateObject(wrappedValue: engine)
        _midi = StateObject(wrappedValue: midi)
        _coordinator = StateObject(wrappedValue: coordinator)
        _httpServer = StateObject(wrappedValue: http)
    }

    var body: some Scene {
        MenuBarExtra("Retrospective", systemImage: menuBarSymbol) {
            MenuBarContent()
                .environmentObject(devices)
                .environmentObject(engine)
                .environmentObject(midi)
                .environmentObject(coordinator)
                .environmentObject(httpServer)
                .onAppear {
                    autoSelectSeeedRecorder()
                }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(devices)
                .environmentObject(engine)
                .environmentObject(midi)
                .environmentObject(coordinator)
                .environmentObject(httpServer)
        }
    }

    private var menuBarSymbol: String {
        if coordinator.state == .extracting {
            return "square.and.arrow.down.fill"
        }
        if !engine.isCapturing {
            return "record.circle.slash"        // no input selected
        }
        if coordinator.lastError != nil {
            return "exclamationmark.triangle.fill"   // last capture failed; clears on next success
        }
        return "record.circle"
    }

    private func autoSelectSeeedRecorder() {
        // Audio input: restore by persisted CoreAudio device UID. This keeps the
        // user's selection across reboots even though the AudioDeviceID changes.
        if engine.selectedDevice == nil,
           let uid = UserDefaults.standard.string(forKey: "audioInputUID"),
           let dev = devices.audioInputs.first(where: { $0.uid == uid }) {
            engine.selectedDevice = dev
        }

        // MIDI: only fall back to "Seeed Recorder" when there's no persisted
        // preference (i.e. user hasn't picked anything yet).
        if midi.sourceName == nil, devices.midiSources.contains("Seeed Recorder") {
            midi.sourceName = "Seeed Recorder"
        }
        if midi.destinationName == nil, devices.midiDestinations.contains("Seeed Recorder") {
            midi.destinationName = "Seeed Recorder"
        }
    }
}
