/// Authorization state needed before any `ControllableAudioSession` can be discovered or
/// controlled (FR-010). See specs/001-per-app-volume-mixer/data-model.md.
public enum PermissionState: Equatable {
    case notDetermined
    case granted
    case denied
}
