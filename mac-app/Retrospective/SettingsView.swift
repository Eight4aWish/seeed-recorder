import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var devices: DeviceEnumerator
    @EnvironmentObject var engine: AudioCaptureEngine
    @EnvironmentObject var midi: MIDIController
    @EnvironmentObject var coordinator: CaptureCoordinator

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
                    Text(coordinator.outputRoot.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            Section {
                Button("Refresh Devices") {
                    devices.refresh()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 580, height: 540)
    }
}
