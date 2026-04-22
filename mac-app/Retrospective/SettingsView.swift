import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var devices: DeviceEnumerator

    @State private var selectedAudioInput: String?
    @State private var selectedMIDISource: String?
    @State private var selectedMIDIDest: String?
    @State private var lookbackMinutes: Double = 5

    var body: some View {
        Form {
            Section("Audio") {
                Picker("Input Device", selection: $selectedAudioInput) {
                    Text("None").tag(String?.none)
                    ForEach(devices.audioInputs, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }

            Section("MIDI") {
                Picker("Source (Seeed → Mac)", selection: $selectedMIDISource) {
                    Text("None").tag(String?.none)
                    ForEach(devices.midiSources, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
                Picker("Destination (Mac → Seeed)", selection: $selectedMIDIDest) {
                    Text("None").tag(String?.none)
                    ForEach(devices.midiDestinations, id: \.self) { name in
                        Text(name).tag(String?.some(name))
                    }
                }
            }

            Section("Capture") {
                LabeledContent("Lookback") {
                    HStack {
                        Slider(value: $lookbackMinutes, in: 0.5...30, step: 0.5)
                        Text("\(lookbackMinutes, specifier: "%.1f") min")
                            .monospacedDigit()
                            .frame(width: 64, alignment: .trailing)
                    }
                }
            }

            Section {
                Button("Refresh Devices") {
                    devices.refresh()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 400)
    }
}
