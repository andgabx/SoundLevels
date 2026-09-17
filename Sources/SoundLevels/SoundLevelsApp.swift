import SwiftUI
import AppKit
import AudioMixerKit

@main
struct SoundLevelsApp: App {
    @StateObject private var viewModel = MixerViewModel(provider: CoreAudioSessionService())

    var body: some Scene {
        MenuBarExtra("SoundLevels", systemImage: "speaker.wave.2.fill") {
            MixerPopoverView(viewModel: viewModel, onOpenSystemSettings: openSystemSettings)
        }
        .menuBarExtraStyle(.window)
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") else { return }
        NSWorkspace.shared.open(url)
    }
}
