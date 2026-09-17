import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// One row per application: icon, name, volume slider, mute toggle (FR-002/FR-003/FR-004).
/// Renders disabled with an explanatory message when the session isn't controllable (FR-011).
/// No business logic here — everything is delegated to `AppVolumeViewModel` (Constitution I).
/// Resolves its own icon (Constitution I keeps `NSImage` out of the Model/ViewModel layers) via
/// `AudioProcessDiscovery.applicationIcon`, which is cheap after the first call per identity
/// thanks to its internal cache (tasks.md T057) — resolved once per row via `.task(id:)`, not on
/// every body re-render, so an interactive slider drag never triggers a fresh lookup.
struct AppVolumeRowView: View {
    @ObservedObject var viewModel: AppVolumeViewModel
    @State private var resolvedIcon: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                appIcon
                Text(viewModel.displayName)
                    .lineLimit(1)
                Spacer()
                Button {
                    viewModel.toggleMute()
                } label: {
                    Image(systemName: viewModel.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)
                .disabled(!viewModel.isControllable)
                .accessibilityLabel(viewModel.isMuted
                    ? Text("Unmute", bundle: .module)
                    : Text("Mute", bundle: .module))
                .accessibilityHint(disabledHint)
            }
            Slider(
                value: Binding(
                    get: { viewModel.volume },
                    set: { viewModel.setVolume($0) }
                ),
                in: 0...1
            )
            .disabled(!viewModel.isControllable)
            .accessibilityLabel(Text(viewModel.displayName))
            .accessibilityValue(Text("\(Int(viewModel.volume * 100))%"))
            .accessibilityHint(disabledHint)

            if !viewModel.isControllable {
                Text("SoundLevels can't control this app's volume individually.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(viewModel.isControllable ? 1.0 : 0.5)
        .task(id: viewModel.identity) {
            #if canImport(AppKit)
            resolvedIcon = AudioProcessDiscovery.applicationIcon(forBundleIdentifier: viewModel.identity)
            #endif
        }
    }

    private var disabledHint: Text {
        viewModel.isControllable
            ? Text(verbatim: "")
            : Text("SoundLevels can't control this app's volume individually.", bundle: .module)
    }

    @ViewBuilder
    private var appIcon: some View {
        if let resolvedIcon {
            Image(nsImage: resolvedIcon)
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
        }
    }
}
