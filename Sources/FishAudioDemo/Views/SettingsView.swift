import SwiftUI
import AVFoundation

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var apiKey: String = KeychainStore.fishAPIKey.read() ?? ""
    @State private var brainKey: String = KeychainStore.brainAPIKey.read() ?? ""
    @State private var status = ""
    @State private var isTesting = false
    @State private var player: AVAudioPlayer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Fish Audio API Key").font(.subheadline.bold())
                SecureField("fs_...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    // ponytail: saved per keystroke. A debounce here loses a pasted key when
                    // the tab switches mid-delay, and a keychain upsert is sub-millisecond.
                    .onChange(of: apiKey) { try? KeychainStore.fishAPIKey.save(apiKey) }

                HStack {
                    Button("Test connection") { testConnection() }
                        .disabled(apiKey.isEmpty || isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                }

                Divider()

                Text("Agent Brain (OpenAI-compatible)").font(.subheadline.bold())
                Text("Defaults to a local Ollama — free, no key needed. Point at OpenAI/Gemini/etc. instead by changing these.")
                    .font(.caption2).foregroundStyle(.secondary)
                TextField("Base URL", text: $settings.brainBaseURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Model", text: $settings.brainModel)
                    .textFieldStyle(.roundedBorder)
                SecureField("API key (optional)", text: $brainKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: brainKey) { try? KeychainStore.brainAPIKey.save(brainKey) }

                if !settings.clonedVoiceReferenceID.isEmpty {
                    Divider()
                    Button("Forget cloned voice") {
                        settings.clonedVoiceReferenceID = ""
                        status = "Cloned voice forgotten (still saved in your Fish Audio account)."
                    }
                    .font(.caption)
                }

                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .frame(width: 290, height: 330)
    }

    private func testConnection() {
        isTesting = true
        status = "Calling Fish Audio…"
        let client = FishAudioClient(apiKey: apiKey)
        Task {
            defer { isTesting = false }
            do {
                let audio = try await client.tts(text: "Hello from Fish Audio.")
                let p = try AVAudioPlayer(data: audio)
                player = p
                p.play()
                status = "Success — playing audio."
            } catch {
                status = error.localizedDescription
            }
        }
    }
}
