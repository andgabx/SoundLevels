import SwiftUI

/// Shown instead of the session list while the Process Tap permission is denied (FR-010).
struct PermissionRequiredView: View {
    let onOpenSystemSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Permission needed")
                .font(.headline)
            Text(
                "AudioMixer needs permission to control other apps' audio volume. " +
                "Grant it in System Settings to see and adjust individual app volumes here."
            )
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            Button("Open System Settings", action: onOpenSystemSettings)
        }
        .padding(20)
        .frame(width: 260)
    }
}
