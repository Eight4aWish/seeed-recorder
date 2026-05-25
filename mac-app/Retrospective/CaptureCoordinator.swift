// Single-press capture trigger:
//
//   .idle       — Seeed LED off. A button press kicks off extraction of the
//                 most recent `lookback` worth of audio.
//   .extracting — Seeed LED solid, scratch is being read on a background
//                 queue, WAVs are being written. Further button presses are
//                 ignored. When the work finishes, LED off, state → .idle.

import Foundation
import AppKit
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "Coordinator")

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

    private func handleButton() {
        switch state {
        case .idle:       triggerCapture()
        case .extracting: break  // Ignore presses while a capture is in flight.
        }
    }

    private func triggerCapture() {
        guard let scratch = engine.scratchBuffer else {
            lastError = "No active capture; pick an audio input first."
            return
        }
        let pressTime = Date()
        lastPressTime = pressTime
        midi.sendLEDOn()
        state = .extracting
        log.info("Capture triggered at \(pressTime.description, privacy: .public)")

        let outputRoot = self.outputRoot
        let stereoPairs = self.stereoPairLefts

        // Disk-bound work runs off the main actor so the UI stays live.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: ExtractionResult?
            let errMsg: String?
            do {
                result = try ScratchExtractor.extract(
                    scratch: scratch,
                    firstPressTime: pressTime,
                    outputRoot: outputRoot,
                    stereoPairLefts: stereoPairs)
                errMsg = nil
            } catch {
                result = nil
                errMsg = error.localizedDescription
                log.error("Extraction failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastResult = result
                // Surface per-channel errors prominently. If extract() itself
                // didn't throw but channels had write failures, the user would
                // otherwise see "0 files saved" with no explanation.
                if let firstError = result?.channelErrors.first {
                    self.lastError = "ch\(firstError.channel + 1): \(firstError.message)"
                } else {
                    self.lastError = errMsg
                }
                self.midi.sendLEDOff()
                self.state = .idle
                if let r = result {
                    log.info("Extracted \(r.writtenFiles.count, privacy: .public) files")
                }
            }
        }
    }
}
