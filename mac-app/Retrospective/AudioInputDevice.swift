import Foundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    /// CoreAudio device UID (kAudioDevicePropertyDeviceUID). Stable across reboots
    /// and unplugs, unlike `id` which is reassigned dynamically. We persist the UID
    /// in UserDefaults so the user's selection survives restarts.
    let uid: String?
    let name: String
}
