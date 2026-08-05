import SwiftUI
import AVFoundation

struct VoiceBrowserView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var voices: [FishAudioClient.VoiceItem] = []
    @State private var statusText = "Loading…"
    @State private var loadingID: String?
    @State private var player: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sample Voices").font(.subheadline.bold())

            if voices.isEmpty {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
                    .font(.caption)
            } else {
                List(voices) { voice in
                    HStack(spacing: 6) {
                        Text(voice.title).lineLimit(1)
                        Spacer()
                        if loadingID == voice.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("▶︎") { preview(voice) }
                                .disabled(loadingID != nil)
                        }
                        Button(settings.defaultVoiceReferenceID == voice.id ? "Default ✓" : "Set default") {
                            settings.defaultVoiceReferenceID = voice.id
                        }
                        .font(.caption)
                    }
                }
                .frame(height: 240)

                if !statusText.isEmpty {
                    Text(statusText).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
        .task { if voices.isEmpty { await load() } }
    }

    private func load() async {
        guard let apiKey = KeychainStore.fishAPIKey.value else {
            statusText = "Set your Fish Audio API key in Settings first."
            return
        }
        statusText = "Loading…"
        do {
            voices = try await FishAudioClient(apiKey: apiKey).listPublicVoices()
            statusText = voices.isEmpty ? "No usable public voices returned." : ""
        } catch {
            statusText = error.localizedDescription
        }
    }

    private func preview(_ voice: FishAudioClient.VoiceItem) {
        guard let apiKey = KeychainStore.fishAPIKey.value else { return }
        loadingID = voice.id
        statusText = ""
        Task {
            defer { loadingID = nil }
            do {
                let audio = try await FishAudioClient(apiKey: apiKey)
                    .tts(text: "Hi, this is a sample of my voice.", referenceId: voice.id)
                let p = try AVAudioPlayer(data: audio)
                player = p
                p.play()
            } catch {
                statusText = error.localizedDescription
            }
        }
    }
}
