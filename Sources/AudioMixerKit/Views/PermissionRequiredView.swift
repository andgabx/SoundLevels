import SwiftUI

/// Shown instead of the session list while the Process Tap permission is denied (FR-010).
struct PermissionRequiredView: View {
    let onOpenSystemSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Permission needed", bundle: .module)
                .font(.headline)
            Text(
                "SoundLevels needs permission to control other apps' audio volume. Grant it in System Settings to see and adjust individual app volumes here.",
                bundle: .module
            )
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            Button(action: onOpenSystemSettings) {
                Text("Open System Settings", bundle: .module)
            }
        }
        .padding(20)
        .frame(width: 260)
    }
}
