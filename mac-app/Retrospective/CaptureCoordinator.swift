// Single-press capture trigger:
//
//   .idle       — Seeed LED off. A button press kicks off extraction of the
//                 most recent `lookback` worth of audio.
//   .extracting — Seeed LED solid, scratch is being read on a background
//                 queue, WAVs are being written. Further button presses are
//                 ignored. When the work finishes, LED off, state → .idle.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "Coordinator")

@MainActor
final class CaptureCoordinator: ObservableObject {
    enum State: String { case idle, extracting }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastPressTime: Date?
    @Published private(set) var lastResult: ExtractionResult?
    @Published private(set) var lastError: String?

    @Published var outputRoot: URL = {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first!
        return music.appendingPathComponent("Retrospective")
    }()

    let midi: MIDIController
    let engine: AudioCaptureEngine

    init(midi: MIDIController, engine: AudioCaptureEngine) {
        self.midi = midi
        self.engine = engine
        midi.onButtonPress = { [weak self] in self?.handleButton() }
        // Defensive: ensure the LED is off when we boot.
        midi.sendLEDOff()
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

        // Disk-bound work runs off the main actor so the UI stays live.
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: ExtractionResult?
            let errMsg: String?
            do {
                result = try ScratchExtractor.extract(
                    scratch: scratch,
                    firstPressTime: pressTime,
                    outputRoot: outputRoot)
                errMsg = nil
            } catch {
                result = nil
                errMsg = error.localizedDescription
                log.error("Extraction failed: \(error.localizedDescription, privacy: .public)")
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.lastResult = result
                self.lastError = errMsg
                self.midi.sendLEDOff()
                self.state = .idle
                if let r = result {
                    log.info("Extracted \(r.writtenFiles.count, privacy: .public) files")
                }
            }
        }
    }
}
