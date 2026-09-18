import CoreAudio
import os

/// Notifies its owner when something about the system's audio output changes in a way that
/// invalidates any live pipeline's assumptions: either the default output device itself changes
/// (AirPods connecting, HDMI, etc.), or the *current* device's sample rate changes without the
/// device itself changing. The second case is a real, confirmed bug source: some apps (Zoom
/// confirmed via manual testing) force the system's current output device to a specific sample
/// rate the moment they start, without ever changing which device is default — so a listener on
/// `kAudioHardwarePropertyDefaultOutputDevice` alone never fires, and every already-running live
/// pipeline keeps operating on its now-stale rate assumption, corrupting every intercepted app's
/// audio at once (not just the app that triggered the rate change).
///
/// Owns only the Core Audio listener registration mechanics — deciding what to do about a change
/// (rebuilding live pipelines) is the caller's job, passed in via `onChange`.
final class DefaultOutputDeviceChangeObserver {
    private let logger = Logger(subsystem: "com.andersongabriel.SoundLevels", category: "DefaultOutputDeviceChangeObserver")
    private var deviceChangeListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: (deviceID: AudioObjectID, block: AudioObjectPropertyListenerBlock)?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    @available(macOS 14.4, *)
    func start() {
        guard deviceChangeListener == nil else { return }
        var address = AudioObjectPropertyReading.address(kAudioHardwarePropertyDefaultOutputDevice)
        // Preserves the exact same single DispatchQueue.main.async hop the previous inline
        // implementation used — no additional dispatch layer between the OS event and `onChange`
        // firing (spec 004 FR-005; resolves regression-safety.md CHK001/CHK009).
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.resubscribeToCurrentDeviceSampleRate()
                self?.onChange()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        if status == noErr {
            deviceChangeListener = block
        } else {
            logger.error("AudioObjectAddPropertyListenerBlock for default output device failed, status=\(status)")
        }
        resubscribeToCurrentDeviceSampleRate()
    }

    @available(macOS 14.4, *)
    func stop() {
        if let deviceChangeListener {
            var address = AudioObjectPropertyReading.address(kAudioHardwarePropertyDefaultOutputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, deviceChangeListener)
            self.deviceChangeListener = nil
        }
        unsubscribeFromCurrentDeviceSampleRate()
    }

    /// Re-points the sample-rate listener at whatever the current default output device now is —
    /// called both on `start()` and every time the default device itself changes, since this
    /// listener targets a specific device object, not the system-wide default-device selector.
    @available(macOS 14.4, *)
    private func resubscribeToCurrentDeviceSampleRate() {
        unsubscribeFromCurrentDeviceSampleRate()
        guard let deviceID = AudioObjectPropertyReading.objectIDProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) else {
            return
        }
        var address = AudioObjectPropertyReading.address(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.onChange()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, nil, block)
        if status == noErr {
            sampleRateListener = (deviceID, block)
        } else {
            logger.error("AudioObjectAddPropertyListenerBlock for nominal sample rate failed, status=\(status)")
        }
    }

    @available(macOS 14.4, *)
    private func unsubscribeFromCurrentDeviceSampleRate() {
        guard let (deviceID, block) = sampleRateListener else { return }
        var address = AudioObjectPropertyReading.address(kAudioDevicePropertyNominalSampleRate)
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, block)
        sampleRateListener = nil
    }
}
