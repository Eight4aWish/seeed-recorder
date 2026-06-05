// Single-press capture trigger.
//
// State:
//   .idle       — Seeed LED off. Any trigger source can start a capture.
//   .extracting — Seeed LED solid, scratch is being read on a background queue,
//                 WAVs are being written. Further triggers from any source are
//                 refused. When the work finishes the LED goes off (success) or
//                 enters the 1 Hz blink (failure) and the state returns to .idle.
//
// Trigger sources (all funnel through `performCapture`):
//   - MIDI Note On from the Seeed (handleButton)
//   - Menu-bar "Capture Now"
//   - HTTP POST /capture
//
// Extraction runs on a detached Task at .userInitiated; the UI stays responsive.

import Foundation
import AppKit
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "Coordinator")

enum CaptureError: Error {
    case alreadyInFlight
    case noAudioSource
    case extractionFailed(String)
}

@MainActor
final class CaptureCoordinator: ObservableObject {
    enum State: String { case idle, extracting }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastPressTime: Date?
    @Published private(set) var lastResult: ExtractionResult?
    @Published private(set) var lastError: String?

    @Published var outputRoot: URL {
        didSet {
            UserDefaults.standard.set(outputRoot.path, forKey: "outputRootPath")
        }
    }

    /// 0-indexed left channels of stereo pairs. Each pairs with the channel after it.
    @Published var stereoPairLefts: Set<Int> {
        didSet {
            UserDefaults.standard.set(Array(stereoPairLefts).sorted(), forKey: "stereoPairLefts")
        }
    }

    let midi: MIDIController
    let engine: AudioCaptureEngine

    init(midi: MIDIController, engine: AudioCaptureEngine) {
        self.midi = midi
        self.engine = engine

        if let saved = UserDefaults.standard.string(forKey: "outputRootPath") {
            self.outputRoot = URL(fileURLWithPath: saved)
        } else {
            let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
            self.outputRoot = music.appendingPathComponent("Retrospective")
        }

        let storedPairs = UserDefaults.standard.array(forKey: "stereoPairLefts") as? [Int] ?? []
        self.stereoPairLefts = Set(storedPairs)

        midi.onButtonPress = { [weak self] in self?.handleButton() }
        // Defensive: ensure the LED is off when we boot.
        midi.sendLEDOff()
    }

    // MARK: - Entry points

    /// MIDI path: fire-and-forget on the MainActor.
    private func handleButton() {
        Task { [weak self] in
            try? await self?.performCapture(source: "midi")
        }
    }

    /// Menu-bar / future non-async callers. Returns false if a capture is
    /// already in flight (caller decides what to do — for the menu-bar button,
    /// nothing; for HTTP, translate to 503 capture_in_flight).
    @discardableResult
    func triggerCaptureFromExternal(source: String) -> Bool {
        guard state == .idle else { return false }
        Task { [weak self] in
            try? await self?.performCapture(source: source)
        }
        return true
    }

    /// Canonical capture path. All trigger sources eventually call this.
    /// Throws `CaptureError.alreadyInFlight` if a capture is in progress and
    /// `CaptureError.noAudioSource` if no input is selected.
    func performCapture(source: String) async throws -> ExtractionResult {
        guard state == .idle else { throw CaptureError.alreadyInFlight }
        guard let scratch = engine.scratchBuffer else { throw CaptureError.noAudioSource }

        let pressTime = Date()
        lastPressTime = pressTime
        midi.sendLEDOn()
        state = .extracting
        log.info("Capture triggered by \(source, privacy: .public) at \(pressTime.description, privacy: .public)")

        let outputRoot = self.outputRoot
        let stereoPairs = self.stereoPairLefts
        let appVersion = Self.appVersion()

        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> ExtractionResult in
                try ScratchExtractor.extract(
                    scratch: scratch,
                    firstPressTime: pressTime,
                    outputRoot: outputRoot,
                    stereoPairLefts: stereoPairs,
                    bpm: nil,                  // Phase 4 wires Link tempo here
                    linkPlaying: false,
                    appVersion: appVersion)
            }.value

            lastResult = result
            if let first = result.channelErrors.first {
                lastError = "ch\(first.channel + 1): \(first.message)"
                midi.sendLEDError()
            } else {
                lastError = nil
                midi.sendLEDOff()
            }
            state = .idle
            log.info("Extracted \(result.writtenFiles.count, privacy: .public) files")
            return result

        } catch {
            lastError = error.localizedDescription
            midi.sendLEDError()
            state = .idle
            log.error("Extraction failed: \(error.localizedDescription, privacy: .public)")
            throw CaptureError.extractionFailed(error.localizedDescription)
        }
    }

    // MARK: - Utilities

    private static func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Show a folder-picker and update `outputRoot` if the user chose one.
    /// No security-scoped bookmark is needed — the app isn't sandboxed yet.
    func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputRoot
        panel.message = "Choose where Retrospective should save WAV captures."
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            outputRoot = url
        }
    }
}
