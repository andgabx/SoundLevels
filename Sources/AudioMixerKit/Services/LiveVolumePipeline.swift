import CoreAudio
import AudioToolbox
import Foundation
import os

final class VolumeBox {
    var volume: Double
    var isMuted: Bool
    init(volume: Double, isMuted: Bool) {
        self.volume = volume
        self.isMuted = isMuted
    }
}

struct LiveVolumePipeline {
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    let ioProcID: AudioDeviceIOProcID
    let box: VolumeBox
}

enum LiveVolumePipelineFactory {
    private static let logger = Logger(subsystem: "com.andersongabriel.SoundLevels", category: "LiveVolumePipeline")

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
