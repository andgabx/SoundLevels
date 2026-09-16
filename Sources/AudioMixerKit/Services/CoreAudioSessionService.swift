import Combine
import CoreAudio
import AudioToolbox
import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Real Core Audio backend for `AudioSessionProviding` — orchestrates permission checks,
/// discovery/polling (`AudioProcessDiscovery`), and per-app live control pipelines
/// (`LiveVolumePipeline`). Built on the public Process Tap API (macOS 14.4+, research.md §1).
/// Not unit-tested — real hardware/permission dialogs aren't practical to simulate — validated
/// manually via quickstart.md instead.
public final class CoreAudioSessionService: AudioSessionProviding {
    private let permissionSubject = CurrentValueSubject<PermissionState, Never>(.notDetermined)
    private let sessionsSubject = CurrentValueSubject<[ControllableAudioSession], Never>([])

    private let graceBuffer = SessionGracePeriodBuffer()
    private var pollTimer: Timer?
    /// The live control pipeline per session identity — only exists while that session needs
    /// anything other than its natural volume; untouched sessions need no pipeline at all.
    private var livePipelines: [String: LiveVolumePipeline] = [:]
    /// Real Core Audio process object IDs currently grouped under each session identity (T034) —
    /// what a live pipeline must tap, instead of an empty process list.
    private var processObjectIDsByIdentity: [String: [AudioObjectID]] = [:]
    /// Whether a tap could actually be created for an identity's processes, probed once per new
    /// identity (T036) — the closest real signal to "Core Audio reports no tappable stream"
    /// (FR-011), since there is no direct query property for it.
    private var tappabilityByIdentity: [String: Bool] = [:]

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
        probeAndUpdatePermission()
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
            permissionSubject.value = .granted
            if pollTimer == nil {
                startPolling()
            }
        } else {
            permissionSubject.value = .denied
            pollTimer?.invalidate()
            pollTimer = nil
            sessionsSubject.value = []
            for pipeline in livePipelines.values {
                LiveVolumePipelineFactory.tearDown(pipeline)
            }
            livePipelines.removeAll()
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

    private func refresh() {
        let processes = AudioProcessDiscovery.fetchAudioProcesses()

        // Track each identity's real process object IDs (T034) so a live pipeline can tap the
        // right processes instead of an empty list.
        var objectIDsByIdentity: [String: [AudioObjectID]] = [:]
        for process in processes {
            objectIDsByIdentity[AudioProcessGrouping.identity(for: process), default: []].append(process.processObjectID)
        }
        processObjectIDsByIdentity = objectIDsByIdentity

        let existingByIdentity = Dictionary(
            uniqueKeysWithValues: sessionsSubject.value.map { ($0.bundleIdentifier, $0) }
        )
        var grouped = AudioProcessGrouping.group(processes: processes, existing: existingByIdentity)

        // Refine isControllable with a real tappability probe (T036, FR-011) rather than only
        // "does this process have a bundle identifier" — probed once per identity, cached, since
        // repeatedly creating/destroying taps every poll cycle would be wasteful.
        for index in grouped.indices {
            let identity = grouped[index].bundleIdentifier
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
        let stillPresent = Set(debounced.map(\.bundleIdentifier))
        tappabilityByIdentity = tappabilityByIdentity.filter { stillPresent.contains($0.key) }
    }

    // MARK: - Control (FR-003/FR-004)

    public func setVolume(_ volume: Double, forBundleIdentifier id: String) {
        guard var session = sessionsSubject.value.first(where: { $0.bundleIdentifier == id }), session.isControllable else {
            print("[AudioMixer] setVolume(\(volume), \(id)): no controllable session found, ignoring")
            return
        }
        session.setVolume(volume)
        applyControl(volume: session.volume, isMuted: session.isMuted, forIdentity: id)
        publish(session)
    }

    public func setMuted(_ isMuted: Bool, forBundleIdentifier id: String) {
        guard var session = sessionsSubject.value.first(where: { $0.bundleIdentifier == id }), session.isControllable else {
            print("[AudioMixer] setMuted(\(isMuted), \(id)): no controllable session found, ignoring")
            return
        }
        session.setMuted(isMuted)
        applyControl(volume: session.volume, isMuted: session.isMuted, forIdentity: id)
        publish(session)
    }

    private func publish(_ session: ControllableAudioSession) {
        var current = sessionsSubject.value
        guard let index = current.firstIndex(where: { $0.bundleIdentifier == session.bundleIdentifier }) else { return }
        current[index] = session
        #if canImport(AppKit)
        if current[index].icon == nil {
            current[index].icon = AudioProcessDiscovery.applicationIcon(forBundleIdentifier: session.bundleIdentifier)
        }
        #endif
        sessionsSubject.value = current
    }

    /// Routes an app's audio through our own live pipeline whenever it needs anything other than
    /// its natural, unmodified volume — silence if muted, `volume`-scaled samples otherwise.
    /// Tears the pipeline down entirely once back at natural (unmuted, volume 1.0) so an
    /// untouched app's audio needs no interception at all.
    private func applyControl(volume: Double, isMuted: Bool, forIdentity identity: String) {
        guard #available(macOS 14.4, *) else { return }

        let needsPipeline = isMuted || volume < 1.0
        guard needsPipeline else {
            if let pipeline = livePipelines.removeValue(forKey: identity) {
                LiveVolumePipelineFactory.tearDown(pipeline)
                print("[AudioMixer] \(identity): back to natural volume, live pipeline torn down")
            }
            return
        }

        if let existing = livePipelines[identity] {
            existing.box.volume = volume
            existing.box.isMuted = isMuted
            return
        }

        let objectIDs = processObjectIDsByIdentity[identity] ?? []
        guard !identity.hasPrefix("process:"), !objectIDs.isEmpty else {
            print("[AudioMixer] \(identity): no process object IDs known — skipping control pipeline")
            return
        }

        guard let pipeline = LiveVolumePipelineFactory.start(
            forIdentity: identity,
            objectIDs: objectIDs,
            initialVolume: volume,
            initialMuted: isMuted
        ) else { return }
        livePipelines[identity] = pipeline
        print("[AudioMixer] \(identity): live control pipeline started (tap \(pipeline.tapID), aggregate \(pipeline.aggregateDeviceID))")
    }
}
