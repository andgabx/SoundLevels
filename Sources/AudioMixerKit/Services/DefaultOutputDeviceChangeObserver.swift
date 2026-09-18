import CoreAudio
import os

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
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.logger.info("kAudioHardwarePropertyDefaultOutputDevice fired — device itself changed")
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

    @available(macOS 14.4, *)
    private func resubscribeToCurrentDeviceSampleRate() {
        unsubscribeFromCurrentDeviceSampleRate()
        guard let deviceID = AudioObjectPropertyReading.objectIDProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) else {
            return
        }
        var address = AudioObjectPropertyReading.address(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.logger.info("kAudioDevicePropertyNominalSampleRate fired for the current output device (id \(deviceID))")
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
