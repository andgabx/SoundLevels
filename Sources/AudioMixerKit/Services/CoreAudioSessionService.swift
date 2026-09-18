import Combine
import CoreAudio
import AudioToolbox
import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

public final class CoreAudioSessionService: AudioSessionProviding {
    private let logger = Logger(subsystem: "com.andersongabriel.SoundLevels", category: "CoreAudioSessionService")

    private let permissionSubject = CurrentValueSubject<PermissionState, Never>(.notDetermined)
    private let sessionsSubject = CurrentValueSubject<[ControllableAudioSession], Never>([])

    private let graceBuffer = SessionGracePeriodBuffer()
    private var pollTimer: Timer?
    private var refreshGeneration = 0
    private var livePipelines: [String: LiveVolumePipeline] = [:]
    private var processObjectIDsByIdentity: [String: [AudioObjectID]] = [:]
    private var tappabilityByIdentity: [String: Bool] = [:]
    private lazy var outputDeviceObserver = DefaultOutputDeviceChangeObserver { [weak self] in
        if #available(macOS 14.4, *) {
            self?.rebuildLivePipelinesForOutputDeviceChange()
        }
    }
    private let volumePreferences: VolumePreferencesProviding

    public var permissionState: AnyPublisher<PermissionState, Never> {
        permissionSubject.eraseToAnyPublisher()
    }

    public var sessions: AnyPublisher<[ControllableAudioSession], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    public init(volumePreferences: VolumePreferencesProviding = UserDefaultsVolumePreferencesStore()) {
        self.volumePreferences = volumePreferences
    }

    deinit {
        pollTimer?.invalidate()
        if #available(macOS 14.4, *) {
            outputDeviceObserver.stop()
            for pipeline in livePipelines.values {
                LiveVolumePipelineFactory.tearDown(pipeline)
            }
        }
    }

    public func requestPermission() {
        guard #available(macOS 14.4, *) else {
            permissionSubject.value = .denied
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let granted = ProcessTapPermissionProbe.checkGranted()
            DispatchQueue.main.async {
                self?.applyPermissionProbeResult(granted: granted)
            }
        }
    }

    @available(macOS 14.4, *)
    private func applyPermissionProbeResult(granted: Bool) {
        if granted {
            permissionSubject.value = .granted
            if pollTimer == nil {
                startPolling()
                outputDeviceObserver.start()
            }
        } else {
            permissionSubject.value = .denied
            pollTimer?.invalidate()
            pollTimer = nil
            outputDeviceObserver.stop()
            sessionsSubject.value = []
            for pipeline in livePipelines.values {
                LiveVolumePipelineFactory.tearDown(pipeline)
            }
            livePipelines.removeAll()
        }
    }

    @available(macOS 14.4, *)
    private func rebuildLivePipelinesForOutputDeviceChange() {
        let currentPipelines = livePipelines
        guard !currentPipelines.isEmpty else { return }
        logger.info("Default output device changed — rebuilding \(currentPipelines.count) live pipeline(s)")
        for (identity, pipeline) in currentPipelines {
            let volume = pipeline.box.volume
            let muted = pipeline.box.isMuted
            LiveVolumePipelineFactory.tearDown(pipeline)
            livePipelines.removeValue(forKey: identity)

            let objectIDs = processObjectIDsByIdentity[identity] ?? []
            guard !objectIDs.isEmpty,
                  let rebuilt = LiveVolumePipelineFactory.start(
                      forIdentity: identity,
                      objectIDs: objectIDs,
                      initialVolume: volume,
                      initialMuted: muted
                  )
            else {
                logger.error("\(identity, privacy: .public): couldn't rebuild live pipeline after output device change (objectIDs.isEmpty=\(objectIDs.isEmpty))")
                continue
            }
            logger.info("\(identity, privacy: .public): live pipeline rebuilt after output device change (new tap \(rebuilt.tapID), aggregate \(rebuilt.aggregateDeviceID))")
            livePipelines[identity] = rebuilt
        }
    }

    @available(macOS 14.4, *)
    private func retapLivePipelinesWithChangedProcesses(newObjectIDsByIdentity: [String: [AudioObjectID]]) {
        let currentPipelines = livePipelines
        for (identity, pipeline) in currentPipelines {
            let oldSet = Set(processObjectIDsByIdentity[identity] ?? [])
            let newSet = Set(newObjectIDsByIdentity[identity] ?? [])
            guard oldSet != newSet, !newSet.isEmpty else { continue }
            logger.info("\(identity, privacy: .public): process set changed, re-tapping live pipeline")
            let volume = pipeline.box.volume
            let muted = pipeline.box.isMuted
            LiveVolumePipelineFactory.tearDown(pipeline)
            livePipelines.removeValue(forKey: identity)

            guard let rebuilt = LiveVolumePipelineFactory.start(
                forIdentity: identity,
                objectIDs: Array(newSet),
                initialVolume: volume,
                initialMuted: muted
            ) else {
                logger.error("\(identity, privacy: .public): couldn't re-tap live pipeline after process set change")
                continue
            }
            livePipelines[identity] = rebuilt
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        refresh()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let processes = AudioProcessDiscovery.fetchAudioProcesses()
            DispatchQueue.main.async {
                guard let self, generation == self.refreshGeneration else { return }
                self.applyRefreshedProcesses(processes)
            }
        }
    }

    private func applyRefreshedProcesses(_ processes: [RawAudioProcess]) {
        var objectIDsByIdentity: [String: [AudioObjectID]] = [:]
        for process in processes {
            objectIDsByIdentity[AudioProcessGrouping.identity(for: process), default: []].append(process.processObjectID)
        }

        if #available(macOS 14.4, *) {
            retapLivePipelinesWithChangedProcesses(newObjectIDsByIdentity: objectIDsByIdentity)
        }
        processObjectIDsByIdentity = objectIDsByIdentity

        let existingByIdentity = Dictionary(
            uniqueKeysWithValues: sessionsSubject.value.map { ($0.identity, $0) }
        )
        var grouped = AudioProcessGrouping.group(processes: processes, existing: existingByIdentity)

        for index in grouped.indices where existingByIdentity[grouped[index].identity] == nil {
            guard let persisted = volumePreferences.persistedState(for: grouped[index].identity) else { continue }
            grouped[index].setVolume(persisted.volume)
            grouped[index].setMuted(persisted.isMuted)
            applyControl(volume: grouped[index].volume, isMuted: grouped[index].isMuted, forIdentity: grouped[index].identity)
        }

        for index in grouped.indices {
            let identity = grouped[index].identity
            guard grouped[index].isControllable else { continue }
            if tappabilityByIdentity[identity] == nil {
                if #available(macOS 14.4, *) {
                    tappabilityByIdentity[identity] = AudioProcessDiscovery.probeTappability(objectIDsByIdentity[identity] ?? [])
                } else {
                    tappabilityByIdentity[identity] = false
                }
            }
            grouped[index].isControllable = tappabilityByIdentity[identity] ?? false
        }

        let debounced = graceBuffer.apply(grouped)
        sessionsSubject.value = debounced

        let stillPresent = Set(debounced.map(\.identity))
        tappabilityByIdentity = tappabilityByIdentity.filter { stillPresent.contains($0.key) }
        if #available(macOS 14.4, *) {
            tearDownPipelinesForRemovedSessions(stillPresent: stillPresent)
        }
    }

    @available(macOS 14.4, *)
    private func tearDownPipelinesForRemovedSessions(stillPresent: Set<String>) {
        let removedIdentities = livePipelines.keys.filter { !stillPresent.contains($0) }
        for identity in removedIdentities {
            guard let pipeline = livePipelines.removeValue(forKey: identity) else { continue }
            LiveVolumePipelineFactory.tearDown(pipeline)
            logger.info("\(identity, privacy: .public): session ended, live pipeline torn down")
        }
    }

    public func setVolume(_ volume: Double, forBundleIdentifier id: String) {
        mutateControllableSession(id: id, operation: "setVolume(\(volume), \(id))") { session in
            session.setVolume(volume)
        } sideEffect: { session in
            volumePreferences.setVolume(session.volume, for: id)
            applyControl(volume: session.volume, isMuted: session.isMuted, forIdentity: id)
        }
    }

    public func setMuted(_ isMuted: Bool, forBundleIdentifier id: String) {
        mutateControllableSession(id: id, operation: "setMuted(\(isMuted), \(id))") { session in
            session.setMuted(isMuted)
        } sideEffect: { session in
            volumePreferences.setMuted(session.isMuted, for: id)
            applyControl(volume: session.volume, isMuted: session.isMuted, forIdentity: id)
        }
    }

    private func mutateControllableSession(
        id: String,
        operation: String,
        mutate: (inout ControllableAudioSession) -> Void,
        sideEffect: (ControllableAudioSession) -> Void
    ) {
        guard var session = sessionsSubject.value.first(where: { $0.identity == id }), session.isControllable else {
            logger.warning("\(operation, privacy: .public): no controllable session found, ignoring")
            return
        }
        mutate(&session)
        sideEffect(session)
        publish(session)
    }

    private func publish(_ session: ControllableAudioSession) {
        var current = sessionsSubject.value
        guard let index = current.firstIndex(where: { $0.identity == session.identity }) else { return }
        current[index] = session
        sessionsSubject.value = current
    }

    private func applyControl(volume: Double, isMuted: Bool, forIdentity identity: String) {
        guard #available(macOS 14.4, *) else { return }

        if let existing = livePipelines[identity] {
            existing.box.volume = volume
            existing.box.isMuted = isMuted
            return
        }

        let needsPipeline = isMuted || volume < 1.0
        guard needsPipeline else { return }

        let objectIDs = processObjectIDsByIdentity[identity] ?? []
        guard !identity.hasPrefix("process:"), !objectIDs.isEmpty else {
            logger.warning("\(identity, privacy: .public): no process object IDs known — skipping control pipeline")
            return
        }

        guard let pipeline = LiveVolumePipelineFactory.start(
            forIdentity: identity,
            objectIDs: objectIDs,
            initialVolume: volume,
            initialMuted: isMuted
        ) else { return }
        livePipelines[identity] = pipeline
        logger.info("\(identity, privacy: .public): live control pipeline started (tap \(pipeline.tapID), aggregate \(pipeline.aggregateDeviceID))")
    }
}
