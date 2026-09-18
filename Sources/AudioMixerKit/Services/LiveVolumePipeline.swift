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
        guard let outputDevice = Self.defaultOutputDevice() else {
            logger.error("\(identity, privacy: .public): couldn't resolve the default output device")
            return nil
        }
        let outputDeviceUID = outputDevice.uid

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
        // risk writing garbage/loud noise from a misinterpreted buffer. Sample rate is
        // deliberately NOT gated here — the IOProc below resamples by proportional frame
        // position, which handles a rate mismatch correctly instead of needing to reject it.
        let tapFormat = Self.tapStreamFormat(tapID)
        let outputSampleRate = AudioObjectPropertyReading.structProperty(outputDevice.id, kAudioDevicePropertyNominalSampleRate, defaultValue: Double(0))
        let canScaleSamples = tapFormat?.mFormatID == kAudioFormatLinearPCM
            && (tapFormat?.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0
            && tapFormat?.mBitsPerChannel == 32
        logger.info("""
            \(identity, privacy: .public): tap format sampleRate=\(tapFormat?.mSampleRate ?? -1) \
            channels=\(tapFormat?.mChannelsPerFrame ?? 0) bitsPerChannel=\(tapFormat?.mBitsPerChannel ?? 0) \
            vs output sampleRate=\(outputSampleRate ?? -1) — canScaleSamples=\(canScaleSamples)
            """)
        if !canScaleSamples {
            logger.warning("\(identity, privacy: .public): tap format isn't Float32 PCM — muting only, no gain scaling")
        }

        let box = VolumeBox(volume: initialVolume, isMuted: initialMuted)

        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, inInputData, _, outOutputData, _ in
            // No logging in here on purpose — this block runs on the real-time audio thread.
            let outputBuffers = UnsafeMutableAudioBufferListPointer(outOutputData)
            guard canScaleSamples else {
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
            for i in 0..<outputBuffers.count {
                guard let outData = outputBuffers[i].mData else { continue }
                // Confirmed via manual testing: some apps' taps run at a different sample rate
                // than the real output device's *current* rate (Zoom's tap reports 48kHz while
                // it forces the system output to 24kHz during a call) — copying samples 1:1 by
                // raw index when rates differ is a de-facto time-stretch (it plays only the
                // first N/ratio samples, stretched to fill the whole output window), producing
                // the deep/robotic voice artifact. Mapping each output frame to the
                // *proportionally* corresponding input frame keeps pitch/speed correct
                // regardless of the actual rate ratio — including the common case where the
                // rates already match, which this formula reduces to a 1:1 copy anyway.
                //
                // Deliberately NOT cross-checking inputBuffers[i].mNumberChannels against
                // outputBuffers[i].mNumberChannels here (tried once, reverted) — Zoom's input
                // AudioBufferList apparently isn't laid out the same way (e.g. non-interleaved
                // vs interleaved) as the output's, so that comparison isn't meaningful buffer-
                // for-buffer and caused Zoom to go permanently silent. Channel count is taken
                // from the output buffer only, same as the pre-2026-09-18 code always did.
                guard i < inputBuffers.count, let inData = inputBuffers[i].mData else {
                    memset(outData, 0, Int(outputBuffers[i].mDataByteSize))
                    continue
                }
                let channels = Int(outputBuffers[i].mNumberChannels)
                guard channels > 0 else {
                    memset(outData, 0, Int(outputBuffers[i].mDataByteSize))
                    continue
                }
                let bytesPerFrame = channels * 4
                let inputFrameCount = Int(inputBuffers[i].mDataByteSize) / bytesPerFrame
                let outputFrameCount = Int(outputBuffers[i].mDataByteSize) / bytesPerFrame
                guard inputFrameCount > 0, outputFrameCount > 0 else {
                    memset(outData, 0, Int(outputBuffers[i].mDataByteSize))
                    continue
                }
                let input = inData.assumingMemoryBound(to: Float.self)
                let output = outData.assumingMemoryBound(to: Float.self)
                for outFrame in 0..<outputFrameCount {
                    let inFrame = min(inputFrameCount - 1, (outFrame * inputFrameCount) / outputFrameCount)
                    for channel in 0..<channels {
                        output[outFrame * channels + channel] = muted ? 0 : input[inFrame * channels + channel] * gain
                    }
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

    private static func defaultOutputDevice() -> (id: AudioObjectID, uid: String)? {
        guard let deviceID = AudioObjectPropertyReading.objectIDProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) else {
            return nil
        }
        guard let uid = AudioObjectPropertyReading.stringProperty(deviceID, kAudioDevicePropertyDeviceUID) else {
            return nil
        }
        return (deviceID, uid)
    }

    private static func tapStreamFormat(_ tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        AudioObjectPropertyReading.structProperty(tapID, kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }
}
