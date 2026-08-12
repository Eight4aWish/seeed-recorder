// The review window: pick a session, hear it.
//
// Layout is a split view — sessions down the left, the selected session's
// channels on the right over a shared transport. Every channel row draws its own
// waveform but they all share one playhead, because they are one performance.
//
// Keyboard first. Auditioning means muting a channel to hear what's underneath
// and putting it back a second later; reaching for the mouse each time breaks
// the listen. Space, digits, M, S, L and the arrow keys all work without moving
// focus off the track list.

import SwiftUI
import AVFoundation

struct ReviewWindow: View {
    @EnvironmentObject var coordinator: CaptureCoordinator
    @EnvironmentObject var devices: DeviceEnumerator

    @StateObject private var library = SessionLibrary()
    @StateObject private var player = SessionPlayer()

    @State private var selectedSessionID: String?
    @State private var focusedTrack: URL?
    /// Files ticked for cleanup. Junk-flagged files start ticked, but nothing is
    /// ever acted on without the user seeing exactly what is selected.
    @State private var checked: Set<URL> = []
    @State private var confirmingTrash = false

    // Tag editor state. Loaded from the selected session's files so existing
    // tags show up rather than being silently overwritten.
    @State private var tagName = ""
    @State private var tagTake = ""
    @State private var tagNote = ""
    @State private var tagGood = false
    @State private var loadedTags = SessionTags()
    @State private var isRetagging = false

    /// Which tag field, if any, currently has the caret.
    ///
    /// The transport shortcuts live on the whole detail pane, and an ancestor
    /// still receives key presses after a focused descendant has had them — so
    /// without this, typing "m" in a session name toggles mute and a space bar
    /// starts playback instead of separating two words.
    private enum TagField: Hashable { case name, take, note }
    @FocusState private var focusedTagField: TagField?

    private var editedTags: SessionTags {
        SessionTags(
            name: tagName.isEmpty ? nil : tagName,
            take: Int(tagTake),
            note: tagNote.isEmpty ? nil : tagNote,
            goodTake: tagGood)
    }

    private var tagsChanged: Bool { editedTags != loadedTags }

    // Junk thresholds live in UserDefaults so the Settings window and this
    // window stay in step without either owning the other.
    @AppStorage(JunkThresholds.activeSecondsKey) private var maxActiveSeconds = JunkThresholds.default.maxActiveSeconds
    @AppStorage(JunkThresholds.eventCountKey) private var maxEventCount = JunkThresholds.default.maxEventCount
    @AppStorage(JunkThresholds.crestKey) private var minCrestDB = Double(JunkThresholds.default.minCrestDB)
    @AppStorage(JunkThresholds.noiseFloorKey) private var maxNoiseFloorDBFS = Double(JunkThresholds.default.maxNoiseFloorDBFS)
    @AppStorage(SessionLibrary.groupGapKey) private var groupGapMinutes = 30.0

    private var thresholds: JunkThresholds {
        JunkThresholds(
            maxActiveSeconds: maxActiveSeconds,
            maxEventCount: maxEventCount,
            minCrestDB: Float(minCrestDB),
            maxNoiseFloorDBFS: Float(maxNoiseFloorDBFS))
    }

    private var selectedSession: CaptureSession? {
        guard let id = selectedSessionID else { return nil }
        return library.session(withID: id)
    }

    private var checkedFiles: [CaptureFile] {
        selectedSession?.files.filter { checked.contains($0.url) } ?? []
    }

    /// Combining needs exactly two mono files from the same session.
    private var combinableFiles: (CaptureFile, CaptureFile)? {
        let mono = checkedFiles.filter { !$0.isStereo }
        guard checkedFiles.count == 2, mono.count == 2 else { return nil }
        return (mono[0], mono[1])
    }

    var body: some View {
        NavigationSplitView {
            sessionList
        } detail: {
            if let session = selectedSession {
                sessionDetail(session)
            } else {
                ContentUnavailableView(
                    "No Session Selected",
                    systemImage: "waveform",
                    description: Text("Pick a capture on the left to audition it."))
            }
        }
        .navigationTitle("Review")
        .frame(minWidth: 900, minHeight: 520)
        .task {
            library.thresholds = thresholds
            library.groupGapMinutes = groupGapMinutes
            if player.outputDeviceID == nil {
                player.setOutputDevice(DeviceEnumerator.defaultOutputDeviceID())
            }
            await library.refresh(root: coordinator.outputRoot)
        }
        .task(id: selectedSessionID) {
            guard let session = selectedSession else { return }
            checked = []
            focusedTagField = nil
            loadTags(from: session)
            player.load(session)
            focusedTrack = session.files.first?.url
            await library.analyze(session)
            // Pre-tick the junk so cleanup is one click, but only after analysis
            // has actually produced a verdict.
            checked = Set(library.flaggedFiles(in: session).map(\.url))
        }
        .onChange(of: thresholds) { _, new in
            library.thresholds = new
        }
        .onChange(of: groupGapMinutes) { _, new in
            library.groupGapMinutes = new
        }
        .onDisappear { player.unload() }
    }

    // MARK: - Sidebar

    private var sessionList: some View {
        // Two levels: a section per sitting (captures close together in time),
        // each listing its individual presses.
        List(selection: $selectedSessionID) {
            ForEach(library.groups) { group in
                Section {
                    ForEach(group.captures) { session in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(session.title).font(.body.monospacedDigit())
                                if let name = session.name {
                                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let junk = library.junkCount(in: session), junk > 0 {
                                    Label("\(junk)", systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                        .labelStyle(.titleAndIcon)
                                }
                            }
                            Text(session.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                        .tag(session.id)
                    }
                } header: {
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title).font(.subheadline.bold())
                            Text(group.subtitle).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let junk = library.junkCount(in: group), junk > 0 {
                            Text("\(junk)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        .overlay {
            if library.sessions.isEmpty, !library.isScanning {
                ContentUnavailableView(
                    "No Captures",
                    systemImage: "tray",
                    description: Text(coordinator.outputRoot.path))
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await library.refresh(root: coordinator.outputRoot) }
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .help("Rescan the captures folder")
            }
        }
    }

    // MARK: - Detail

    private func sessionDetail(_ session: CaptureSession) -> some View {
        VStack(spacing: 0) {
            header(session)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(player.tracks) { track in
                        TrackRow(
                            track: track,
                            stats: library.stats[track.id],
                            junkReasons: library.stats[track.id]?.junkReasons(thresholds) ?? [],
                            isFocused: focusedTrack == track.id,
                            isChecked: checked.contains(track.id),
                            progress: progress,
                            player: player,
                            onFocus: { focusedTrack = track.id },
                            onToggleCheck: {
                                if checked.contains(track.id) { checked.remove(track.id) }
                                else { checked.insert(track.id) }
                            })
                        Divider()
                    }
                }
            }

            Divider()
            TransportBar(player: player, devices: devices)
        }
        // Focus lives on the whole pane so the shortcuts work wherever you click.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down, action: handleKey)
    }

    private func header(_ session: CaptureSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name ?? session.title)
                        .font(.headline)
                    Text("\(session.dateText) · \(session.title) · \(session.subtitle)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !library.analyzing.isEmpty {
                    ProgressView().controlSize(.small)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting(session.files.map(\.url))
                } label: {
                    Label("Reveal", systemImage: "folder")
                }
                .help("Reveal this session's files in Finder")
            }

            // Tags apply to the whole capture — every file from one press.
            HStack(spacing: 8) {
                TextField("Session name", text: $tagName)
                    .frame(maxWidth: 200)
                    .focused($focusedTagField, equals: .name)
                TextField("Take", text: $tagTake)
                    .frame(width: 52)
                    .focused($focusedTagField, equals: .take)
                Toggle(isOn: $tagGood) {
                    Label("Good", systemImage: tagGood ? "star.fill" : "star")
                }
                .toggleStyle(.button)
                .help("iXML CIRCLED — the field-recorder mark for a keeper")

                TextField("Notes", text: $tagNote)
                    .focused($focusedTagField, equals: .note)

                Button {
                    applyTags(to: session)
                } label: {
                    if isRetagging {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Apply Tags")
                    }
                }
                .disabled(!tagsChanged || isRetagging)
                .help("Write these into every file in the capture, for DaVinci Resolve")
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                // Return commits and releases the caret, so the next keystroke
                // is a transport shortcut again.
                focusedTagField = nil
                if tagsChanged { applyTags(to: session) }
            }

            HStack(spacing: 8) {
                Text(checked.isEmpty
                     ? "Nothing selected"
                     : "\(checked.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Select Flagged") {
                    checked = Set(library.flaggedFiles(in: session).map(\.url))
                }
                .font(.caption)
                .disabled(library.flaggedFiles(in: session).isEmpty)

                Button("Clear") { checked = [] }
                    .font(.caption)
                    .disabled(checked.isEmpty)

                Spacer()

                Button {
                    combineChecked(in: session)
                } label: {
                    Label("Combine to Stereo", systemImage: "arrow.triangle.merge")
                }
                .disabled(combinableFiles == nil)
                .help(combinableFiles == nil
                      ? "Tick exactly two mono channels to pair them"
                      : "Pair these two channels into one stereo file")

                Button(role: .destructive) {
                    confirmingTrash = true
                } label: {
                    Label("Move to Trash", systemImage: "trash")
                }
                .disabled(checked.isEmpty)
            }

            if let error = library.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .confirmationDialog(
            "Move \(checked.count) file\(checked.count == 1 ? "" : "s") to the Trash?",
            isPresented: $confirmingTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { trashChecked(in: session) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They stay recoverable from the Finder Trash until you empty it.")
        }
    }

    // MARK: - Cleanup actions

    /// Both operations release the player's file handles first — it holds an
    /// open AVAudioFile per track, and those files are about to move.
    private func trashChecked(in session: CaptureSession) {
        let files = checkedFiles
        guard !files.isEmpty else { return }
        Task {
            player.unload()
            await library.trash(files, root: coordinator.outputRoot)
            checked = []
            await reloadSelectedSession()
        }
    }

    private func combineChecked(in session: CaptureSession) {
        guard let (a, b) = combinableFiles else { return }
        Task {
            player.unload()
            await library.combine(
                a, b,
                in: session,
                root: coordinator.outputRoot,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")
            checked = []
            await reloadSelectedSession()
        }
    }

    private func applyTags(to session: CaptureSession) {
        focusedTagField = nil
        isRetagging = true
        let tags = editedTags
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"

        Task {
            // Retagging rewrites and renames every file in the capture; the
            // player has all of them open.
            player.unload()
            let result = await Task.detached(priority: .userInitiated) {
                Retagger.applyToSession(tags, session: session, appVersion: version)
            }.value

            if let first = result.errors.first {
                library.report(error: "\(first.file): \(first.message)")
            } else {
                library.clearError()
            }
            await library.refresh(root: coordinator.outputRoot)
            loadedTags = tags
            isRetagging = false
            await reloadSelectedSession()
        }
    }

    /// Show whatever the files already carry, so editing one field does not
    /// blank the others.
    private func loadTags(from session: CaptureSession) {
        let existing = session.files.first.flatMap { try? WAVReader.tags(at: $0.url) }
        let tags = SessionTags(
            name: existing?.sessionName ?? session.name,
            take: existing?.take ?? session.take,
            note: existing?.note,
            goodTake: existing?.goodTake ?? false)

        tagName = tags.name ?? ""
        tagTake = tags.take.map(String.init) ?? ""
        tagNote = tags.note ?? ""
        tagGood = tags.goodTake
        loadedTags = tags
    }

    /// Re-point the player at whatever the session now contains. The session id
    /// is unchanged by cleanup, so `.task(id:)` will not fire on its own.
    private func reloadSelectedSession() async {
        guard let session = selectedSession else {
            selectedSessionID = library.sessions.first?.id
            return
        }
        player.load(session)
        focusedTrack = session.files.first?.url
        await library.analyze(session)
    }

    private var progress: Double {
        player.totalFrames > 0 ? Double(player.positionFrames) / Double(player.totalFrames) : 0
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // While a tag field has the caret, every key belongs to it — letters,
        // spaces and the arrow keys alike. Escape hands focus back so the
        // transport shortcuts work again.
        if focusedTagField != nil {
            if press.key == .escape {
                focusedTagField = nil
                return .handled
            }
            return .ignored
        }

        switch press.key {
        case .space:
            player.togglePlayPause(); return .handled
        case .leftArrow:
            player.skip(bySeconds: press.modifiers.contains(.shift) ? -1 : -5); return .handled
        case .rightArrow:
            player.skip(bySeconds: press.modifiers.contains(.shift) ? 1 : 5); return .handled
        case .upArrow:
            moveFocus(-1); return .handled
        case .downArrow:
            moveFocus(1); return .handled
        default:
            break
        }

        switch press.characters.lowercased() {
        case "m":
            if let id = focusedTrack { player.toggleMute(id) }
            return .handled
        case "s":
            if let id = focusedTrack { player.toggleSolo(id) }
            return .handled
        case "l":
            player.isLooping.toggle(); return .handled
        case "[":
            stepTransient(forward: false); return .handled
        case "]":
            stepTransient(forward: true); return .handled
        case "0":
            player.clearSolo(); return .handled
        case let d where d.count == 1 && d.first!.isNumber:
            // Digits solo by position — 1 is the first channel in the list.
            let index = Int(d)! - 1
            if player.tracks.indices.contains(index) {
                player.toggleSolo(player.tracks[index].id)
            }
            return .handled
        default:
            return .ignored
        }
    }

    private func moveFocus(_ delta: Int) {
        guard !player.tracks.isEmpty else { return }
        let current = player.tracks.firstIndex { $0.id == focusedTrack } ?? 0
        let next = max(0, min(player.tracks.count - 1, current + delta))
        focusedTrack = player.tracks[next].id
    }

    private func stepTransient(forward: Bool) {
        guard let id = focusedTrack, let stats = library.stats[id] else { return }
        player.stepTransient(using: stats, forward: forward)
    }
}

// MARK: - Track row

private struct TrackRow: View {
    let track: SessionPlayer.Track
    let stats: SignalStats?
    let junkReasons: [JunkReason]
    let isFocused: Bool
    let isChecked: Bool
    let progress: Double
    @ObservedObject var player: SessionPlayer
    let onFocus: () -> Void
    let onToggleCheck: () -> Void

    private var isAudible: Bool { player.isAudible(track.id) }

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isChecked }, set: { _ in onToggleCheck() }))
                .labelsHidden()
                .help("Select for combining or trashing")

            VStack(alignment: .leading, spacing: 3) {
                Text(track.file.channelLabel)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(isFocused ? .bold : .regular)
                HStack(spacing: 4) {
                    toggleButton("M", isOn: track.isMuted, tint: .orange) {
                        player.toggleMute(track.id)
                    }
                    toggleButton("S", isOn: player.soloed.contains(track.id), tint: .blue) {
                        player.toggleSolo(track.id)
                    }
                }
            }
            .frame(width: 78, alignment: .leading)

            WaveformView(
                envelope: stats?.envelope ?? .empty,
                progress: progress,
                isAudible: isAudible,
                isJunk: !junkReasons.isEmpty,
                onScrub: { fraction in
                    onFocus()
                    player.seek(toFraction: fraction)
                })
                .frame(height: 46)

            statsColumn
                .frame(width: 132, alignment: .leading)

            Slider(
                value: Binding(
                    get: { track.volume },
                    set: { player.setVolume($0, for: track.id) }),
                in: 0...1)
                .frame(width: 80)
                .help("Track level")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isFocused ? Color.accentColor.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { onFocus() }
    }

    private var statsColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let stats {
                Text(String(format: "%.1f pk · %.1f rms", stats.peakDBFS, stats.rmsDBFS))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if junkReasons.isEmpty {
                    Text(String(format: "crest %.0f · %@ live", stats.crestDB, Self.activeText(stats)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                } else {
                    Label(junkReasons.map(\.label).joined(separator: ", "), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    // Active time is the clause that decided it — show the number
                    // that was judged, not a derived percentage.
                    Text("\(Self.activeText(stats)) live · \(stats.eventCount) events")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text("analysing…").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// Sub-second activity is where the junk boundary sits, so show ms there.
    private static func activeText(_ stats: SignalStats) -> String {
        stats.activeSeconds < 1
            ? String(format: "%.0f ms", stats.activeSeconds * 1000)
            : String(format: "%.1f s", stats.activeSeconds)
    }

    private func toggleButton(_ label: String, isOn: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.bold())
                .frame(width: 20, height: 16)
                .background(isOn ? tint : Color.secondary.opacity(0.15))
                .foregroundStyle(isOn ? .white : .secondary)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Waveform

private struct WaveformView: View {
    let envelope: WaveformEnvelope
    let progress: Double
    let isAudible: Bool
    let isJunk: Bool
    /// Fraction 0...1 of the capture the user scrubbed to.
    let onScrub: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    let mid = size.height / 2
                    guard envelope.bucketCount > 0 else {
                        context.stroke(
                            Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: size.width, y: mid)) },
                            with: .color(.secondary.opacity(0.3)))
                        return
                    }

                    // Normalise to the loudest bucket so quiet captures are still
                    // legible — this is a shape to navigate by, not a meter.
                    let extent = max(
                        envelope.maxValues.max() ?? 1,
                        abs(envelope.minValues.min() ?? -1))
                    let scale = extent > 0 ? Double(mid) / Double(extent) : 0

                    var path = Path()
                    let columns = Int(size.width)
                    for x in 0..<max(1, columns) {
                        let bucket = envelope.bucketCount * x / max(1, columns)
                        guard bucket < envelope.bucketCount else { break }
                        let top = mid - CGFloat(Double(envelope.maxValues[bucket]) * scale)
                        let bottom = mid - CGFloat(Double(envelope.minValues[bucket]) * scale)
                        path.move(to: CGPoint(x: CGFloat(x), y: min(top, bottom)))
                        path.addLine(to: CGPoint(x: CGFloat(x), y: max(bottom, top) + 0.5))
                    }
                    context.stroke(path, with: .color(waveColor), lineWidth: 1)
                }

                Rectangle()
                    .fill(Color.red)
                    .frame(width: 1.5)
                    .offset(x: geo.size.width * CGFloat(min(1, max(0, progress))))
                    .allowsHitTesting(false)
            }
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onScrub(min(1, max(0, Double(value.location.x / max(1, geo.size.width)))))
                    })
        }
    }

    private var waveColor: Color {
        if !isAudible { return .secondary.opacity(0.3) }
        return isJunk ? .orange : .accentColor
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @ObservedObject var player: SessionPlayer
    @ObservedObject var devices: DeviceEnumerator

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    player.togglePlayPause()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 24)
                }
                .help("Play / pause (Space)")

                Button {
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .help("Stop")

                Timeline(player: player)

                Text("\(format(player.positionSeconds)) / \(format(player.duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)

                Toggle(isOn: $player.isLooping) {
                    Image(systemName: "repeat")
                }
                .toggleStyle(.button)
                .help("Loop (L). Drag on the timeline to set a region.")
            }

            HStack(spacing: 12) {
                Picker("Out", selection: outputBinding) {
                    Text("System Default").tag(AudioDeviceID?.none)
                    ForEach(devices.audioOutputs) { device in
                        Text(device.name).tag(AudioDeviceID?.some(device.id))
                    }
                }
                .frame(maxWidth: 300)

                Spacer()

                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.secondary)
                Slider(value: $player.masterGainDB, in: -12...24)
                    .frame(width: 140)
                Text(String(format: "%+.0f dB", player.masterGainDB))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)

                if player.hasSolo {
                    Button("Clear Solo") { player.clearSolo() }
                        .font(.caption)
                }
            }

            if let error = player.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var outputBinding: Binding<AudioDeviceID?> {
        Binding(
            get: { player.outputDeviceID },
            set: { player.setOutputDevice($0 ?? DeviceEnumerator.defaultOutputDeviceID()) })
    }

    private func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let total = Int(seconds)
        let tenths = Int((seconds - Double(total)) * 10)
        return String(format: "%d:%02d.%d", total / 60, total % 60, tenths)
    }
}

/// Scrubber that doubles as the loop-region editor: a click seeks, a drag marks
/// a region to loop.
private struct Timeline: View {
    @ObservedObject var player: SessionPlayer
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2)).frame(height: 5)

                if let region = player.loopRegion, player.totalFrames > 0 {
                    let lo = Double(region.lowerBound) / Double(player.totalFrames)
                    let hi = Double(region.upperBound) / Double(player.totalFrames)
                    Capsule()
                        .fill(Color.accentColor.opacity(0.25))
                        .frame(width: width * CGFloat(hi - lo), height: 5)
                        .offset(x: width * CGFloat(lo))
                }

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 11, height: 11)
                    .offset(x: width * CGFloat(fraction) - 5.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let start = dragStart ?? clamp(value.startLocation.x / width)
                        dragStart = start
                        let now = clamp(value.location.x / width)
                        if abs(value.translation.width) > 4 {
                            setLoop(from: start, to: now)
                        } else {
                            player.seek(toFraction: now)
                        }
                    }
                    .onEnded { value in
                        if abs(value.translation.width) <= 4 {
                            // A click with no drag clears any region and seeks.
                            player.loopRegion = nil
                            player.seek(toFraction: clamp(value.location.x / width))
                        }
                        dragStart = nil
                    })
        }
        .frame(height: 20)
    }

    private var fraction: Double {
        player.totalFrames > 0 ? Double(player.positionFrames) / Double(player.totalFrames) : 0
    }

    private func clamp(_ v: CGFloat) -> Double { min(1, max(0, Double(v))) }

    private func setLoop(from a: Double, to b: Double) {
        guard player.totalFrames > 0 else { return }
        let lo = AVAudioFramePosition(min(a, b) * Double(player.totalFrames))
        let hi = AVAudioFramePosition(max(a, b) * Double(player.totalFrames))
        guard hi > lo else { return }
        player.loopRegion = lo...hi
    }
}
