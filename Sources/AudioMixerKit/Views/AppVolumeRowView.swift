import SwiftUI

/// One row per application: icon, name, volume slider, mute toggle (FR-002/FR-003/FR-004).
/// Renders disabled with an explanatory message when the session isn't controllable (FR-011).
/// No business logic here — everything is delegated to `AppVolumeViewModel` (Constitution I).
struct AppVolumeRowView: View {
    @ObservedObject var viewModel: AppVolumeViewModel

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
            }
            Slider(
                value: Binding(
                    get: { viewModel.volume },
                    set: { viewModel.setVolume($0) }
                ),
                in: 0...1
            )
            .disabled(!viewModel.isControllable)

            if !viewModel.isControllable {
                Text("SoundLevels can't control this app's volume individually.", bundle: .module)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(viewModel.isControllable ? 1.0 : 0.5)
    }

    @ViewBuilder
    private var appIcon: some View {
        #if canImport(AppKit)
        if let icon = viewModel.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.dashed")
                .frame(width: 20, height: 20)
        }
        #else
        Image(systemName: "app.dashed")
            .frame(width: 20, height: 20)
        #endif
    }
}
