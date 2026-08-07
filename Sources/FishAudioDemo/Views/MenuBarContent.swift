import SwiftUI

private enum Tab: String, CaseIterable {
    case voices = "Voices"
    case clone = "Clone"
    case agent = "Agent"
    case settings = "Settings"
}

struct MenuBarContent: View {
    @State private var tab: Tab = .voices
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding([.horizontal, .top], 12)

            switch tab {
            case .voices: VoiceBrowserView()
            case .clone: VoiceCloneView()
            case .agent: VoiceAgentView()
            case .settings: SettingsView()
            }

            Divider()
            Button("Transcribe a Call…") {
                openWindow(id: "transcript")
                // Clicking a menu bar item doesn't activate an .accessory app, so the window
                // opens *behind* whatever is frontmost and the button looks dead.
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .padding(.bottom, 10)
        }
    }
}
