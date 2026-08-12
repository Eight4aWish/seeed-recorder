// Sample-locked multitrack audition for one capture session.
//
// A session's files are one performance recorded to N files, so they have to be
// heard together, locked. One AVAudioPlayerNode per file feeds the main mixer,
// and every node is started at a single shared `AVAudioTime` — that shared time
// is the entire sync mechanism.
//
// Three rules keep it locked:
//
//   1. Mute sets `node.volume = 0`. It never stops the node. Stopping and
//      restarting one node would put it out of step with the rest, which is
//      exactly the thing a mute during audition must not do.
//   2. Pause and seek stop *every* node and reschedule at a fresh shared time.
//      Resuming individually paused nodes drifts; a clean re-sync does not.
//   3. Start times are host-time based, not sample-time based. The capture
//      device (48 kHz Scarlett) and the monitoring device (44.1 kHz speakers)
//      often disagree, and the mixer resamples between them — host time is the
//      one clock both sides share.
//
// Playback streams from disk via `scheduleSegment`. Buffering instead would cost
// ~184 MB for 16 channels at the 60 s default and ~5.5 GB at the 30-minute max.

import Foundation
import AVFoundation
import CoreAudio
import OSLog

private let log = Logger(subsystem: "com.n8synth.retrospective", category: "SessionPlayer")

@MainActor
final class SessionPlayer: ObservableObject {

    struct Track: Identifiable {
        let file: CaptureFile
        let node: AVAudioPlayerNode
        let audioFile: AVAudioFile
        var volume: Float = 1
        var isMuted = false

        var id: URL { file.url }
        var frameCount: AVAudioFramePosition { audioFile.length }
    }

    // MARK: Published state

    @Published private(set) var tracks: [Track] = []
    @Published private(set) var isPlaying = false
    @Published private(set) var positionFrames: AVAudioFramePosition = 0
    @Published private(set) var totalFrames: AVAudioFramePosition = 0
    @Published private(set) var sampleRate: Double = 48_000
    @Published private(set) var loadedSessionID: String?
    @Published private(set) var lastError: String?

    @Published private(set) var soloed: Set<URL> = []

    @Published var isLooping = false {
        didSet { if isLooping != oldValue { rescheduleIfPlaying() } }
    }

    /// Loop region in frames. nil loops the whole capture.
    @Published var loopRegion: ClosedRange<AVAudioFramePosition>? {
        didSet { if isLooping { rescheduleIfPlaying() } }
    }

    /// Monitoring gain. Retrospective captures are often quiet and need lifting
    /// before they can be judged at all.
    @Published var masterGainDB: Float = 0 {
        didSet { applyVolumes() }
    }

    @Published private(set) var outputDeviceID: AudioDeviceID?

    // MARK: Internals

    private var engine = AVAudioEngine()
    /// Frame the current playback run was scheduled from — the origin that
    /// player-relative elapsed time is measured against.
    private var runStartFrame: AVAudioFramePosition = 0
    private var displayTimer: Timer?

    /// Loop iterations queued up front. `scheduleSegment` only queues a
    /// descriptor, so pre-arming 64 passes costs nothing and avoids the
    /// completion-handler race that per-iteration rescheduling invites.
    private static let loopPrescheduleCount = 64
    /// Lead-in before the shared start time. Long enough for every node to be
    /// primed, short enough not to feel like latency.
    private static let leadInSeconds: TimeInterval = 0.12

    var duration: TimeInterval { sampleRate > 0 ? Double(totalFrames) / sampleRate : 0 }

    var positionSeconds: TimeInterval { sampleRate > 0 ? Double(positionFrames) / sampleRate : 0 }

    var hasSolo: Bool { !soloed.isEmpty }

    // MARK: - Loading

    func load(_ session: CaptureSession) {
        guard session.id != loadedSessionID else { return }
        unload()

        var built: [Track] = []
        var minLength: AVAudioFramePosition = .max
        var rate: Double = 0

        for file in session.files {
            do {
                let audioFile = try AVAudioFile(forReading: file.url)
                let node = AVAudioPlayerNode()
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: audioFile.processingFormat)
                built.append(Track(file: file, node: node, audioFile: audioFile))
                minLength = min(minLength, audioFile.length)
                rate = max(rate, audioFile.processingFormat.sampleRate)
            } catch {
                log.error("Could not open \(file.url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                lastError = "Could not open \(file.url.lastPathComponent)."
            }
        }

        tracks = built
        totalFrames = built.isEmpty ? 0 : minLength
        sampleRate = rate > 0 ? rate : 48_000
        positionFrames = 0
        runStartFrame = 0
        loopRegion = nil
        loadedSessionID = session.id

        guard !built.isEmpty else { return }
        applyOutputDevice()
        applyVolumes()
        startEngine()
    }

    func unload() {
        stop()
        engine.stop()
        for track in tracks {
            engine.disconnectNodeOutput(track.node)
            engine.detach(track.node)
        }
        tracks = []
        totalFrames = 0
        positionFrames = 0
        loadedSessionID = nil
        soloed = []
    }

    private func startEngine() {
        guard !engine.isRunning, !tracks.isEmpty else { return }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            lastError = "Audio engine failed to start: \(error.localizedDescription)"
            log.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Transport

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !tracks.isEmpty, !isPlaying else { return }
        startEngine()
        guard engine.isRunning else { return }

        // Restart from the top once the playhead has run out.
        if positionFrames >= totalFrames { positionFrames = 0 }

        schedule(from: positionFrames)
        startNodesTogether()
        isPlaying = true
        startDisplayTimer()
    }

    /// Pause is a stop that remembers where it was. Resuming re-syncs from
    /// scratch rather than un-pausing nodes individually.
    func pause() {
        guard isPlaying else { return }
        let frame = positionFrames
        haltNodes()
        positionFrames = frame
        isPlaying = false
    }

    func stop() {
        haltNodes()
        positionFrames = 0
        isPlaying = false
    }

    func seek(toFrame frame: AVAudioFramePosition) {
        let clamped = max(0, min(totalFrames, frame))
        positionFrames = clamped
        guard isPlaying else { return }
        haltNodesKeepingPlayingFlag()
        schedule(from: clamped)
        startNodesTogether()
    }

    func seek(toSeconds seconds: TimeInterval) {
        seek(toFrame: AVAudioFramePosition(seconds * sampleRate))
    }

    /// Fractional seek, 0...1 — what the scrubber drives.
    func seek(toFraction fraction: Double) {
        seek(toFrame: AVAudioFramePosition(Double(totalFrames) * max(0, min(1, fraction))))
    }

    func skip(bySeconds delta: TimeInterval) {
        seek(toFrame: positionFrames + AVAudioFramePosition(delta * sampleRate))
    }

    /// Jump to the next/previous detected transient on a track. On a sparse or
    /// suspected-junk channel this is the difference between hearing the three
    /// clicks immediately and scrubbing through a minute of silence.
    func stepTransient(using stats: SignalStats, forward: Bool) {
        let current = positionFrames
        // Land slightly early so the attack itself is audible.
        let preroll = AVAudioFramePosition(0.005 * sampleRate)
        let targets = stats.transientFrames.map { AVAudioFramePosition($0) }

        let next: AVAudioFramePosition?
        if forward {
            next = targets.first { $0 > current + preroll }
        } else {
            next = targets.last { $0 < current - preroll }
        }
        guard let next else { return }
        seek(toFrame: max(0, next - preroll))
    }

    // MARK: - Mixing

    func toggleMute(_ id: URL) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].isMuted.toggle()
        applyVolumes()
    }

    func toggleSolo(_ id: URL) {
        if soloed.contains(id) { soloed.remove(id) } else { soloed.insert(id) }
        applyVolumes()
    }

    func clearSolo() {
        soloed = []
        applyVolumes()
    }

    func setVolume(_ volume: Float, for id: URL) {
        guard let i = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[i].volume = volume
        applyVolumes()
    }

    func isAudible(_ id: URL) -> Bool {
        guard let track = tracks.first(where: { $0.id == id }) else { return false }
        return !track.isMuted && (soloed.isEmpty || soloed.contains(id))
    }

    private func applyVolumes() {
        let master = powf(10, masterGainDB / 20)
        for track in tracks {
            track.node.volume = isAudible(track.id) ? track.volume * master : 0
        }
    }

    // MARK: - Output device

    func setOutputDevice(_ id: AudioDeviceID?) {
        outputDeviceID = id
        let wasPlaying = isPlaying
        let frame = positionFrames

        // The device property can only be set while the engine is stopped.
        haltNodes()
        engine.stop()
        applyOutputDevice()
        startEngine()

        positionFrames = frame
        isPlaying = false
        if wasPlaying { play() }
    }

    private func applyOutputDevice() {
        guard let deviceID = outputDeviceID, let unit = engine.outputNode.audioUnit else { return }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size))
        if status != noErr {
            lastError = "Could not switch monitoring device (OSStatus \(status))."
            log.error("Output device set failed: \(status, privacy: .public)")
        }
    }

    // MARK: - Scheduling

    private var loopBounds: (start: AVAudioFramePosition, end: AVAudioFramePosition) {
        if let region = loopRegion {
            return (max(0, region.lowerBound), min(totalFrames, region.upperBound))
        }
        return (0, totalFrames)
    }

    /// Queues each node's audio. Every node gets an identical schedule, so once
    /// they start together they stay together.
    private func schedule(from frame: AVAudioFramePosition) {
        runStartFrame = frame
        let bounds = loopBounds
        let tail = (isLooping ? bounds.end : totalFrames) - frame

        for track in tracks {
            track.node.stop()

            if tail > 0 {
                let count = min(tail, track.frameCount - frame)
                if count > 0 {
                    track.node.scheduleSegment(
                        track.audioFile,
                        startingFrame: frame,
                        frameCount: AVAudioFrameCount(count),
                        at: nil,
                        completionHandler: nil)
                }
            }

            guard isLooping else { continue }
            let loopLength = bounds.end - bounds.start
            guard loopLength > 0 else { continue }
            for _ in 0..<Self.loopPrescheduleCount {
                let count = min(loopLength, track.frameCount - bounds.start)
                guard count > 0 else { break }
                track.node.scheduleSegment(
                    track.audioFile,
                    startingFrame: bounds.start,
                    frameCount: AVAudioFrameCount(count),
                    at: nil,
                    completionHandler: nil)
            }
        }
    }

    /// The sync point: one host time, handed to every node.
    private func startNodesTogether() {
        let startTime = AVAudioTime(
            hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: Self.leadInSeconds))
        for track in tracks {
            track.node.play(at: startTime)
        }
    }

    private func haltNodes() {
        haltNodesKeepingPlayingFlag()
        stopDisplayTimer()
    }

    private func haltNodesKeepingPlayingFlag() {
        for track in tracks { track.node.stop() }
    }

    private func rescheduleIfPlaying() {
        guard isPlaying else { return }
        let frame = positionFrames
        haltNodesKeepingPlayingFlag()
        schedule(from: frame)
        startNodesTogether()
    }

    // MARK: - Playhead

    private func startDisplayTimer() {
        stopDisplayTimer()
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickPlayhead() }
        }
        RunLoop.main.add(timer, forMode: .common)   // keeps ticking while menus/scrubber track
        displayTimer = timer
    }

    private func stopDisplayTimer() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func tickPlayhead() {
        guard isPlaying, let elapsed = elapsedPlayerFrames() else { return }
        let position = positionFor(elapsed: elapsed)

        if !isLooping, position >= totalFrames {
            positionFrames = totalFrames
            haltNodes()
            isPlaying = false
            return
        }
        positionFrames = position
    }

    /// Frames since this playback run began, in the player's own timeline.
    /// nil until the shared start time is actually reached.
    private func elapsedPlayerFrames() -> AVAudioFramePosition? {
        guard let node = tracks.first?.node,
              let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return nil }
        return max(0, playerTime.sampleTime)
    }

    /// Maps elapsed run time onto a position in the capture, accounting for the
    /// loop wrap. The first pass runs from wherever playback started to the loop
    /// end; every pass after that is a full region.
    private func positionFor(elapsed: AVAudioFramePosition) -> AVAudioFramePosition {
        guard isLooping else { return min(totalFrames, runStartFrame + elapsed) }

        let bounds = loopBounds
        let firstPass = bounds.end - runStartFrame
        if elapsed < firstPass { return runStartFrame + elapsed }

        let loopLength = bounds.end - bounds.start
        guard loopLength > 0 else { return bounds.start }
        return bounds.start + (elapsed - firstPass) % loopLength
    }
}
