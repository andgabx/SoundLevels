import Combine
import CoreAudio
import AudioToolbox
import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

/// Real Core Audio backend for `AudioSessionProviding` — orchestrates permission checks,
/// discovery/polling (`AudioProcessDiscovery`), and per-app live control pipelines
/// (`LiveVolumePipeline`). Built on the public Process Tap API (macOS 14.4+, research.md §1).
/// Not unit-tested — real hardware/permission dialogs aren't practical to simulate — validated
/// manually via quickstart.md instead.
public final class CoreAudioSessionService: AudioSessionProviding {
    private let logger = Logger(subsystem: "com.andersongabriel.SoundLevels", category: "CoreAudioSessionService")

    private let permissionSubject = CurrentValueSubject<PermissionState, Never>(.notDetermined)
    private let sessionsSubject = CurrentValueSubject<[ControllableAudioSession], Never>([])

    private let graceBuffer = SessionGracePeriodBuffer()
    private var pollTimer: Timer?
    /// Guards against a background `refresh()` fetch completing out of order relative to a more
    /// recent one (T060) — only the latest dispatched fetch's results are ever applied.
    private var refreshGeneration = 0
    /// The live control pipeline per session identity. Once created for an identity, it is kept
    /// running for that session's entire lifetime — NOT torn down just because volume returns to
    /// 1.0/unmuted. Setting `box.volume = 1.0` / `box.isMuted = false` makes the IOProc's output
    /// byte-for-byte identical to unmodified passthrough (a multiply by 1.0), so there is no
    /// audible difference between "natural" and "pipeline running at natural gain" — but tearing
    /// the Aggregate Device down and recreating it IS audible every single time, no matter how
    /// infrequently. An earlier version of this debounced the teardown instead of eliminating it;
    /// manual testing confirmed the debounce only spaced the glitches out, it didn't remove them
    /// (tasks.md T053 follow-up). Torn down only when the identity's session actually disappears
    /// (`tearDownPipelinesForRemovedSessions`), on permission revocation, or in `deinit`.
    private var livePipelines: [String: LiveVolumePipeline] = [:]
    /// Real Core Audio process object IDs currently grouped under each session identity (T034) —
    /// what a live pipeline must tap, instead of an empty process list.
    private var processObjectIDsByIdentity: [String: [AudioObjectID]] = [:]
    /// Whether a tap could actually be created for an identity's processes, probed once per new
    /// identity (T036) — the closest real signal to "Core Audio reports no tappable stream"
    /// (FR-011), since there is no direct query property for it.
    private var tappabilityByIdentity: [String: Bool] = [:]
    /// Registered while permission is granted (T041) so a default output device change (AirPods
    /// connecting, HDMI, etc.) rebuilds any live pipelines instead of leaving them silently
    /// pointing at a device that's no longer the output — each pipeline bakes the output device
    /// UID in at creation time (see `LiveVolumePipelineFactory`).
    private var outputDeviceChangeListener: AudioObjectPropertyListenerBlock?

    public var permissionState: AnyPublisher<PermissionState, Never> {
        permissionSubject.eraseToAnyPublisher()
    }

    public var sessions: AnyPublisher<[ControllableAudioSession], Never> {
        sessionsSubject.eraseToAnyPublisher()
    }

    public init() {}

    deinit {
        pollTimer?.invalidate()
        if #available(macOS 14.4, *) {
            stopObservingDefaultOutputDeviceChanges()
            for pipeline in livePipelines.values {
                LiveVolumePipelineFactory.tearDown(pipeline)
            }
        }
    }

    // MARK: - Permission (FR-010)

    public func requestPermission() {
        guard #available(macOS 14.4, *) else {
            permissionSubject.value = .denied
            return
        }
        // Re-probing every time (not just once) lets this double as the "re-check" T012 asked
        // for: called again from MixerPopoverView.onAppear each time the popover opens, so a
        // permission grant/revocation made in System Settings while denied/granted is picked up
        // on the next open, in both directions — without polling in the background forever.
        // The actual HAL round-trip runs off the main thread (T060) — this is on the direct
        // "user just clicked the menu bar icon" path, so keeping it off main matters for SC-001.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.probeAndUpdatePermission()
        }
    }

    @available(macOS 14.4, *)
    private func probeAndUpdatePermission() {
        // Probing with a harmless, immediately-destroyed global tap is the documented way to
        // trigger (and observe the result of) the system's Process Tap permission prompt, since
        // there is no dedicated "request access" API for this capability. Once already granted
        // or denied, this call doesn't re-show any dialog — it just reports the OS's current
        // answer, which is exactly what we need to detect a change made in System Settings.
        let probe = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        var tapID: AudioObjectID = 0
        let status = AudioHardwareCreateProcessTap(probe, &tapID)
        if status == noErr {
            AudioHardwareDestroyProcessTap(tapID)
        }
        let granted = status == noErr
        DispatchQueue.main.async { [weak self] in
            self?.applyPermissionProbeResult(granted: granted)
        }
    }

    @available(macOS 14.4, *)
    private func applyPermissionProbeResult(granted: Bool) {
        if granted {
            permissionSubject.value = .granted
            if pollTimer == nil {
                startPolling()
                startObservingDefaultOutputDeviceChanges()
            }
        } else {
            permissionSubject.value = .denied
            pollTimer?.invalidate()
            pollTimer = nil
            stopObservingDefaultOutputDeviceChanges()
            sessionsSubject.value = []
            for pipeline in livePipelines.values {
                LiveVolumePipelineFactory.tearDown(pipeline)
            }
            livePipelines.removeAll()
        }
    }

    /// Rebuilds every live pipeline against whatever the default output device now is (T041).
    /// Each pipeline bakes the output device UID in at creation time — there is no in-place
    /// "retarget" API — so a real device change requires tearing down and recreating, preserving
    /// the volume/mute state each pipeline already had.
    @available(macOS 14.4, *)
    private func startObservingDefaultOutputDeviceChanges() {
        guard outputDeviceChangeListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.rebuildLivePipelinesForOutputDeviceChange()
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
        if status == noErr {
            outputDeviceChangeListener = listener
        } else {
            logger.error("AudioObjectAddPropertyListenerBlock for default output device failed, status=\(status)")
        }
    }

    @available(macOS 14.4, *)
    private func stopObservingDefaultOutputDeviceChanges() {
        guard let listener = outputDeviceChangeListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, nil, listener)
        outputDeviceChangeListener = nil
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
                logger.error("\(identity, privacy: .public): couldn't rebuild live pipeline after output device change")
                continue
            }
            livePipelines[identity] = rebuilt
        }
    }

    /// Re-taps any live pipeline whose underlying process set changed since the last poll (T054)
    /// — e.g. a muted/attenuated app spawning a new audio-producing helper process (a new browser
    /// tab, say). Without this, that new process's audio bypassed the existing tap entirely and
    /// played at full volume, unmuted, while the UI still showed the row as muted. Mirrors
    /// `rebuildLivePipelinesForOutputDeviceChange`'s tear-down-and-recreate pattern, preserving
    /// volume/mute state. Skips an identity whose new process set is empty — that's the grace
    /// period keeping a momentarily-silent session visible, not a real process-set change, and
    /// re-tapping an empty list would just destroy a still-useful pipeline for nothing.
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

    // MARK: - Discovery (FR-002, FR-005)

    private func startPolling() {
        pollTimer?.invalidate()
        refresh()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// The actual Core Audio/AppKit discovery work (`AudioProcessDiscovery.fetchAudioProcesses`)
    /// runs off the main thread (T060) — it's real HAL/LaunchServices round-trip work, run once a
    /// second forever. Only the result-application step below (`applyRefreshedProcesses`) touches
    /// shared state, and it always runs back on main.
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
        // Track each identity's real process object IDs (T034) so a live pipeline can tap the
        // right processes instead of an empty list.
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

        // Refine isControllable with a real tappability probe (T036, FR-011) rather than only
        // "does this process have a bundle identifier" — probed once per identity, cached, since
        // repeatedly creating/destroying taps every poll cycle would be wasteful.
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

        // T045: without this, tappabilityByIdentity would grow forever across a long-running
        // session touching many transient identities (e.g. many different websites' WebKit
        // helpers) — each one probed once and then never forgotten.
        let stillPresent = Set(debounced.map(\.identity))
        tappabilityByIdentity = tappabilityByIdentity.filter { stillPresent.contains($0.key) }
        if #available(macOS 14.4, *) {
            tearDownPipelinesForRemovedSessions(stillPresent: stillPresent)
        }
    }

    /// The only place a live pipeline is torn down for a reason other than permission revocation
    /// or `deinit` — when the identity's session has actually disappeared (app quit, or stopped
    /// producing audio past the grace period), not merely because volume/mute returned to
    /// natural. See `livePipelines`'s doc comment for why "natural volume" alone must never tear
    /// a pipeline down.
    @available(macOS 14.4, *)
    private func tearDownPipelinesForRemovedSessions(stillPresent: Set<String>) {
        let removedIdentities = livePipelines.keys.filter { !stillPresent.contains($0) }
        for identity in removedIdentities {
            guard let pipeline = livePipelines.removeValue(forKey: identity) else { continue }
            LiveVolumePipelineFactory.tearDown(pipeline)
            logger.info("\(identity, privacy: .public): session ended, live pipeline torn down")
        }
    }

    // MARK: - Control (FR-003/FR-004)

    public func setVolume(_ volume: Double, forBundleIdentifier id: String) {
        guard var session = sessionsSubject.value.first(where: { $0.identity == id }), session.isControllable else {
            logger.warning("setVolume(\(volume), \(id, privacy: .public)): no controllable session found, ignoring")
            return
        }
        session.setVolume(volume)
        applyControl(volume: session.volume, isMuted: session.isMuted, forIdentity: id)
        publish(session)
    }

    public func setMuted(_ isMuted: Bool, forBundleIdentifier id: String) {
        guard var session = sessionsSubject.value.first(where: { $0.identity == id }), session.isControllable else {
            logger.warning("setMuted(\(isMuted), \(id, privacy: .public)): no controllable session found, ignoring")
            return
        }
        session.setMuted(isMuted)
        applyControl(volume: session.volume, isMuted: session.isMuted, forIdentity: id)
        publish(session)
    }

    private func publish(_ session: ControllableAudioSession) {
        var current = sessionsSubject.value
        guard let index = current.firstIndex(where: { $0.identity == session.identity }) else { return }
        current[index] = session
        sessionsSubject.value = current
    }

    /// Routes an app's audio through our own live pipeline whenever it needs anything other than
    /// its natural, unmodified volume — silence if muted, `volume`-scaled samples otherwise. Once
    /// created for an identity, the pipeline is kept running indefinitely (see `livePipelines`'s
    /// doc comment) — it is never torn down here just because volume/mute returned to natural.
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
