import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var devices: DeviceEnumerator
    @EnvironmentObject var engine: AudioCaptureEngine
    @EnvironmentObject var midi: MIDIController
    @EnvironmentObject var coordinator: CaptureCoordinator
    @EnvironmentObject var httpServer: HTTPServer

    // Shared with the review window through UserDefaults — see JunkThresholds.
    @AppStorage(JunkThresholds.activeSecondsKey) private var maxActiveSeconds = JunkThresholds.default.maxActiveSeconds
    @AppStorage(JunkThresholds.eventCountKey) private var maxEventCount = JunkThresholds.default.maxEventCount
    @AppStorage(JunkThresholds.crestKey) private var minCrestDB = Double(JunkThresholds.default.minCrestDB)
    @AppStorage(JunkThresholds.noiseFloorKey) private var maxNoiseFloorDBFS = Double(JunkThresholds.default.maxNoiseFloorDBFS)
    @AppStorage(SessionLibrary.groupGapKey) private var groupGapMinutes = 30.0

    private var lookbackMinutes: Binding<Double> {
        Binding(
            get: { engine.lookbackSeconds / 60 },
            set: { engine.lookbackSeconds = $0 * 60 }
        )
    }

    var body: some View {
        Form {
            Section("Audio") {
                Picker("Input Device", selection: $engine.selectedDevice) {
                    Text("None").tag(AudioInputDevice?.none)
                    ForEach(devices.audioInputs) { dev in
                        Text(dev.name).tag(AudioInputDevice?.some(dev))
                    }
                }
                if engine.isCapturing {
                    LabeledContent("Format") {
                        Text("\(engine.channelCount) ch · \(Int(engine.sampleRate)) Hz · \(engine.bitsPerChannel)-bit")
                            .foregroundStyle(.secondary)
                    }
                    if let path = engine.scratchPath {
                        LabeledContent("Scratch") {
                            Text(path).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                        }
                    }
                }
                if let err = engine.lastError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }

            Section("MIDI") {
                Picker("Source (Seeed → Mac)", selection: $midi.sourceName) {
                    Text("None").tag(String?.none)
                    ForEach(devices.midiSources, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                Picker("Destination (Mac → Seeed)", selection: $midi.destinationName) {
                    Text("None").tag(String?.none)
                    ForEach(devices.midiDestinations, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                if let err = midi.lastError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }

            Section("Capture") {
                LabeledContent("Lookback") {
                    HStack {
                        Slider(value: lookbackMinutes, in: 0.5...30, step: 0.5)
                        Text("\(lookbackMinutes.wrappedValue, specifier: "%.1f") min")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
                if engine.isCapturing {
                    Text("Lookback changes apply on next capture start.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Output") {
                    HStack {
                        Text(coordinator.outputRoot.path)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            coordinator.chooseOutputFolder()
                        }
                    }
                }
            }

            Section("Stereo Pairs") {
                if engine.isCapturing, engine.channelCount >= 2 {
                    Text("Marked pairs save as one interleaved stereo WAV; everything else stays mono.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(stride(from: 0, to: engine.channelCount - 1, by: 2)), id: \.self) { left in
                        Toggle("Channels \(left + 1) + \(left + 2)", isOn: Binding(
                            get: { coordinator.stereoPairLefts.contains(left) },
                            set: { on in
                                if on { coordinator.stereoPairLefts.insert(left) }
                                else { coordinator.stereoPairLefts.remove(left) }
                            }
                        ))
                    }
                } else {
                    Text("Select an audio input to configure stereo pairs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("HTTP / Bonjour") {
                LabeledContent("Listener") {
                    Text(httpServer.isRunning
                         ? "Listening on TCP/\(httpServer.port) · advertised as \(HTTPServer.bonjourName)"
                         : "Not running")
                        .foregroundStyle(.secondary)
                }
                if let err = httpServer.lastError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }

            Section("Review · Grouping") {
                LabeledContent("New session after") {
                    HStack {
                        Slider(value: $groupGapMinutes, in: 5...240, step: 5)
                        Text(groupGapMinutes >= 60
                             ? String(format: "%.1f h", groupGapMinutes / 60)
                             : String(format: "%.0f min", groupGapMinutes))
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Text("Captures further apart than this are shown as separate sessions. In this library, gaps within a sitting topped out at 20 minutes and the next gap up was 53, so 30 minutes separates them cleanly.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Review · Junk Detection") {
                Text("A channel is flagged when it carries almost no signal but a loud peak — stray clicks from a half-seated patch cable rather than a take. Flagging never deletes anything.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Max live time") {
                    HStack {
                        Slider(value: $maxActiveSeconds, in: 0.05...5, step: 0.05)
                        Text("\(maxActiveSeconds, specifier: "%.2f") s")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }
                Text("Measured across this library, stray clicks totalled at most 0.02 s of signal while the shortest real take ran 2.56 s. Anything between the two is safe.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                LabeledContent("Min crest") {
                    HStack {
                        Slider(value: $minCrestDB, in: 10...50, step: 1)
                        Text("\(minCrestDB, specifier: "%.0f") dB")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }

                LabeledContent("Max events") {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { Double(maxEventCount) },
                                set: { maxEventCount = Int($0) }),
                            in: 1...64, step: 1)
                        Text("\(maxEventCount)")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }

                LabeledContent("Max floor") {
                    HStack {
                        Slider(value: $maxNoiseFloorDBFS, in: -96...(-30), step: 1)
                        Text("\(maxNoiseFloorDBFS, specifier: "%.0f") dBFS")
                            .monospacedDigit()
                            .frame(width: 60, alignment: .trailing)
                    }
                }

                Button("Restore Defaults") {
                    maxActiveSeconds = JunkThresholds.default.maxActiveSeconds
                    minCrestDB = Double(JunkThresholds.default.minCrestDB)
                    maxEventCount = JunkThresholds.default.maxEventCount
                    maxNoiseFloorDBFS = Double(JunkThresholds.default.maxNoiseFloorDBFS)
                }
            }

            Section {
                Button("Refresh Devices") {
                    devices.refresh()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 600)
    }
}
