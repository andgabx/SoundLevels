import SwiftUI

public struct MixerPopoverView: View {
    @ObservedObject var viewModel: MixerViewModel
    let onOpenSystemSettings: () -> Void

    public init(viewModel: MixerViewModel, onOpenSystemSettings: @escaping () -> Void) {
        self.viewModel = viewModel
        self.onOpenSystemSettings = onOpenSystemSettings
    }

    public var body: some View {
        Group {
            switch viewModel.listState {
            case .permissionRequired:
                PermissionRequiredView(onOpenSystemSettings: onOpenSystemSettings)
            case .empty:
                VStack(spacing: 8) {
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("No apps are currently playing audio")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(width: 240)
            case .sessions:
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(viewModel.rowViewModels) { rowViewModel in
                        AppVolumeRowView(viewModel: rowViewModel)
                        Divider()
                    }
                }
                .padding(12)
                .frame(width: 280)
            }
        }
        .onAppear { viewModel.requestPermission() }
    }
}
