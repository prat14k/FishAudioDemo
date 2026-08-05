import SwiftUI

@main
struct FishAudioDemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("FishAudioDemo", systemImage: "waveform") {
            MenuBarContent()
        }
        .menuBarExtraStyle(.window)

        Window("Live Transcript", id: "transcript") {
            TranscriptWindowView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 420, height: 500)
    }
}
