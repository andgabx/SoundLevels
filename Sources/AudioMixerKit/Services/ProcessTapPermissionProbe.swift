import CoreAudio
import AudioToolbox

enum ProcessTapPermissionProbe {
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
