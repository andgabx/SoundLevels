import Combine

/// Coordinates the popover/session-list: permission gating, the visible session list, and one
/// `AppVolumeViewModel` per listed application (Constitution Principles I & II).
public final class MixerViewModel: ObservableObject {
    public enum SessionListState: Equatable {
        case loading
        case permissionRequired
        case empty
        case sessions
    }

    @Published public private(set) var permissionState: PermissionState = .notDetermined
    @Published public private(set) var rowViewModels: [AppVolumeViewModel] = []
    @Published public private(set) var listState: SessionListState = .loading

    private let provider: AudioSessionProviding
    private var cancellables = Set<AnyCancellable>()
    private var rowViewModelsByIdentity: [String: AppVolumeViewModel] = [:]
    private var latestSessions: [ControllableAudioSession] = []

    public init(provider: AudioSessionProviding) {
        self.provider = provider

        provider.permissionState
            .sink { [weak self] state in
                self?.permissionState = state
                self?.recompute()
            }
            .store(in: &cancellables)

        provider.sessions
            .sink { [weak self] sessions in
                self?.latestSessions = sessions
                self?.recompute()
            }
            .store(in: &cancellables)
    }

    public func requestPermission() {
        provider.requestPermission()
    }

    /// Rebuilds `rowViewModels` from the latest known state, reusing existing `AppVolumeViewModel`
    /// instances for bundle identifiers still present (US3, FR-005) so an in-flight slider drag
    /// isn't reset, and dropping ones no longer present. While permission is `.denied`, sessions
    /// are never read (contract expectation #1) — the list is cleared and `.permissionRequired`
    /// is exposed instead (FR-010).
    private func recompute() {
        guard permissionState != .denied else {
            rowViewModels = []
            rowViewModelsByIdentity = [:]
            listState = .permissionRequired
            return
        }

        var updated: [AppVolumeViewModel] = []
        var updatedByIdentity: [String: AppVolumeViewModel] = [:]

        for session in latestSessions {
            if let existing = rowViewModelsByIdentity[session.bundleIdentifier] {
                existing.updateSession(session)
                updated.append(existing)
                updatedByIdentity[session.bundleIdentifier] = existing
            } else {
                let rowViewModel = AppVolumeViewModel(session: session, provider: provider)
                updated.append(rowViewModel)
                updatedByIdentity[session.bundleIdentifier] = rowViewModel
            }
        }

        rowViewModels = updated
        rowViewModelsByIdentity = updatedByIdentity
        listState = updated.isEmpty ? .empty : .sessions
    }
}
