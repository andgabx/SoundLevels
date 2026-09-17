import CoreAudio
import AudioToolbox
import Foundation
import os

/// Mutable, thread-shared state for one live pipeline's volume/mute — read from the real-time
/// audio thread inside the IOProc, written from the main thread when the user moves a slider.
/// Deliberately unsynchronized: both fields are simple scalars where a torn read is harmless
/// (worst case, one stale sample), which is an accepted trade-off to avoid locks on the audio
/// thread. Revisit if this ever needs to be provably safe under strict concurrency checking.
final class VolumeBox {
    var volume: Double
    var isMuted: Bool
    init(volume: Double, isMuted: Bool) {
        self.volume = volume
        self.isMuted = isMuted
    }
}

/// The tap + private Aggregate Device (tap + real output sub-device) + running IOProc that makes
/// both mute AND continuous volume audible for one application.
///
/// Manual testing (2026-09-16) confirmed `CATapDescription.muteBehavior` alone has NO audible
/// effect until the tap is part of a live IO cycle — Core Audio only enforces it once the tap is
/// actually running inside an Aggregate Device. To get continuous gain (not just mute), the tap
/// is always set `.muted` once this pipeline exists (stopping the app's direct passthrough to
/// hardware entirely), and the IOProc itself reads the tap's captured samples, scales them by
/// `box.volume` (silence if `box.isMuted`), and writes the result to the real output device
/// included in the same aggregate — making this pipeline the sole path by which that app's audio
/// reaches the speakers while it's active.
struct LiveVolumePipeline {
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    let ioProcID: AudioDeviceIOProcID
    let box: VolumeBox
}

enum LiveVolumePipelineFactory {
    private static let logger = Logger(subsystem: "com.andersongabriel.SoundLevels", category: "LiveVolumePipeline")

    /// Builds a tap (always `.muted`, since this pipeline becomes the sole path to the speakers
    /// once it exists), wraps it in a private Aggregate Device alongside the real default output
    /// device, and starts an `AudioDeviceIOProc` that scales the tap's captured samples by
    /// `box.volume` and writes them to that real device — this is what makes both mute AND
    /// continuous volume audible (see `LiveVolumePipeline` doc).
    @available(macOS 14.4, *)
    static func start(
        forIdentity identity: String,
        objectIDs: [AudioObjectID],
        initialVolume: Double,
        initialMuted: Bool
    ) -> LiveVolumePipeline? {
        guard let outputDeviceUID = Self.defaultOutputDeviceUID() else {
            logger.error("\(identity, privacy: .public): couldn't resolve the default output device UID")
            return nil
        }

        let tapUUID = UUID()
        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        description.uuid = tapUUID
        description.isPrivate = true
        description.muteBehavior = .muted

        var tapID: AudioObjectID = 0
        guard AudioHardwareCreateProcessTap(description, &tapID) == noErr else {
            logger.error("\(identity, privacy: .public): AudioHardwareCreateProcessTap failed")
            return nil
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SoundLevels-\(identity)",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapUUID.uuidString]
            ]
        ]

        var aggregateDeviceID: AudioObjectID = 0
        guard AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID) == noErr else {
            logger.error("\(identity, privacy: .public): AudioHardwareCreateAggregateDevice failed")
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        // Defensive: only attempt sample-accurate scaling if the tap's format is exactly what we
        // expect (Linear PCM, Float32). If it's anything else, fall back to silence rather than
        // risk writing garbage/loud noise from a misinterpreted buffer.
        let tapFormat = Self.tapStreamFormat(tapID)
        let canScaleSamples = tapFormat?.mFormatID == kAudioFormatLinearPCM
            && (tapFormat?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0
            && tapFormat?.mBitsPerChannel == 32
        if !canScaleSamples {
            logger.warning("\(identity, privacy: .public): tap format isn't Float32 PCM (\(String(describing: tapFormat), privacy: .public)) — muting only, no gain scaling")
        }

        let box = VolumeBox(volume: initialVolume, isMuted: initialMuted)

        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, inInputData, _, outOutputData, _ in
            // No logging in here on purpose — this block runs on the real-time audio thread.
            let outputBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard canScaleSamples else {
                // Actually fall back to silence, not whatever the HAL happened to leave in the
                // buffer — the comment above promised this, but a bare `return` here never wrote
                // anything (a real bug: tasks.md T055). Since the tap is always `.muted` at the
                // source, this IOProc is the only path audio reaches speakers once a pipeline
                // exists, so an unmet "fall back to silence" guarantee is a real risk, not
                // cosmetic.
                for i in 0..<outputBuffers.count {
                    if let outData = outputBuffers[i].mData {
                        memset(outData, 0, Int(outputBuffers[i].mDataByteSize))
                    }
                }
                return
            }
            let muted = box.isMuted
            let gain = Float(max(0.0, min(1.0, box.volume)))
            let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            for i in 0..<min(inputBuffers.count, outputBuffers.count) {
                guard let inData = inputBuffers[i].mData, let outData = outputBuffers[i].mData else { continue }
                let sampleCount = min(inputBuffers[i].mDataByteSize, outputBuffers[i].mDataByteSize) / 4
                let input = inData.assumingMemoryBound(to: Float.self)
                let output = outData.assumingMemoryBound(to: Float.self)
                for sample in 0..<Int(sampleCount) {
                    output[sample] = muted ? 0 : input[sample] * gain
                }
            }
        }
        guard ioStatus == noErr, let ioProcID else {
            logger.error("\(identity, privacy: .public): AudioDeviceCreateIOProcIDWithBlock failed, status=\(ioStatus)")
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else {
            logger.error("\(identity, privacy: .public): AudioDeviceStart failed, status=\(startStatus)")
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            AudioHardwareDestroyProcessTap(tapID)
            return nil
        }

        return LiveVolumePipeline(tapID: tapID, aggregateDeviceID: aggregateDeviceID, ioProcID: ioProcID, box: box)
    }

    @available(macOS 14.4, *)
    static func tearDown(_ pipeline: LiveVolumePipeline?) {
        guard let pipeline else { return }
        AudioDeviceStop(pipeline.aggregateDeviceID, pipeline.ioProcID)
        AudioDeviceDestroyIOProcID(pipeline.aggregateDeviceID, pipeline.ioProcID)
        AudioHardwareDestroyAggregateDevice(pipeline.aggregateDeviceID)
        AudioHardwareDestroyProcessTap(pipeline.tapID)
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioObjectID = 0
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr else {
            return nil
        }
        return AudioObjectPropertyReading.stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    private static func tapStreamFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }
}
