import Combine

public final class MixerViewModel: ObservableObject {
    public enum SessionListState: Equatable {
        case permissionRequired
        case empty
        case sessions
    }

    @Published public private(set) var permissionState: PermissionState = .notDetermined
    @Published public private(set) var rowViewModels: [AppVolumeViewModel] = []
    @Published public private(set) var listState: SessionListState = .empty

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
            if let existing = rowViewModelsByIdentity[session.identity] {
                updated.append(existing)
                updatedByIdentity[session.identity] = existing
            } else {
                let rowViewModel = AppVolumeViewModel(session: session, provider: provider)
                updated.append(rowViewModel)
                updatedByIdentity[session.identity] = rowViewModel
            }
        }

        rowViewModels = updated
        rowViewModelsByIdentity = updatedByIdentity
        listState = updated.isEmpty ? .empty : .sessions
    }
}
