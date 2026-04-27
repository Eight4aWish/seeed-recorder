import Foundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let name: String
}
