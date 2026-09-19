import SwiftUI

struct PermissionRequiredView: View {
    let onOpenSystemSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Permission needed")
                .font(.headline)
            Text(
                "SoundLevels needs permission to control other apps' audio volume. Grant it in System Settings to see and adjust individual app volumes here."
            )
            .font(.callout)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            Button(action: onOpenSystemSettings) {
                Text("Open System Settings")
            }
        }
        .padding(20)
        .frame(width: 260)
    }
}
