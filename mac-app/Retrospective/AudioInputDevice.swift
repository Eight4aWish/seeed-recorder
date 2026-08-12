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

/// Monitoring device for the review window's audition path.
///
/// Same shape as `AudioInputDevice`, deliberately a separate type: the capture
/// device (a Scarlett) and the monitoring device (usually not) are different
/// roles, and the compiler should stop one being passed where the other belongs.
struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String?
    let name: String
}
