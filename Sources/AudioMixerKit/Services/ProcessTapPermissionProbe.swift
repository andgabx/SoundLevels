import CoreAudio
import AudioToolbox

/// Stateless mechanics for checking whether the Process Tap permission is currently granted.
/// See specs/004-core-audio-service-refactor/research.md §1.
enum ProcessTapPermissionProbe {
    /// Probing with a harmless, immediately-destroyed global tap is the documented way to
    /// trigger (and observe the result of) the system's Process Tap permission prompt, since
    /// there is no dedicated "request access" API for this capability. Once already granted or
    /// denied, this call doesn't re-show any dialog — it just reports the OS's current answer.
    @available(macOS 14.4, *)
    static func checkGranted() -> Bool {
        let probe = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(probe, &tapID)
        if status == noErr {
            AudioHardwareDestroyProcessTap(tapID)
        }
        return status == noErr
    }
}
