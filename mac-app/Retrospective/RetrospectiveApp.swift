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

    init() {
        let engine = AudioCaptureEngine()
        let midi = MIDIController()
        _engine = StateObject(wrappedValue: engine)
        _midi = StateObject(wrappedValue: midi)
        _coordinator = StateObject(wrappedValue: CaptureCoordinator(midi: midi, engine: engine))
    }

    var body: some Scene {
        MenuBarExtra("Retrospective", systemImage: menuBarSymbol) {
            MenuBarContent()
                .environmentObject(devices)
                .environmentObject(engine)
                .environmentObject(midi)
                .environmentObject(coordinator)
                .onAppear { autoSelectSeeedRecorder() }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(devices)
                .environmentObject(engine)
                .environmentObject(midi)
                .environmentObject(coordinator)
        }
    }

    private var menuBarSymbol: String {
        switch coordinator.state {
        case .idle:       return "record.circle"
        case .extracting: return "square.and.arrow.down.fill"
        }
    }

    private func autoSelectSeeedRecorder() {
        if midi.sourceName == nil, devices.midiSources.contains("Seeed Recorder") {
            midi.sourceName = "Seeed Recorder"
        }
        if midi.destinationName == nil, devices.midiDestinations.contains("Seeed Recorder") {
            midi.destinationName = "Seeed Recorder"
        }
    }
}
