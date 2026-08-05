import SwiftUI
import AVFoundation

private let clonePromptSentence = "The quick brown fox jumps over the lazy dog, while the five boxing wizards jump quickly."
/// Fish Audio's fast clone wants a clean 10-30s sample; below ~10s quality falls apart.
private let minimumCloneSeconds: TimeInterval = 10

struct VoiceCloneView: View {
    @ObservedObject private var settings = AppSettings.shared
    @StateObject private var recorder = AudioRecorder()
    @State private var statusText = ""
    @State private var isBusy = false
    @State private var uploadTask: Task<Void, Never>?
    @State private var player: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clone Your Voice").font(.subheadline.bold())
            Text("Read this aloud for at least \(Int(minimumCloneSeconds))s (repeat it if you finish early):")
                .font(.caption).foregroundStyle(.secondary)
            Text(clonePromptSentence)
                .font(.callout.italic())
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)

            HStack {
                if recorder.isRecording {
                    Button("Stop (\(String(format: "%.0fs", recorder.elapsed)))") { stopAndUpload() }
                        .disabled(recorder.elapsed < minimumCloneSeconds)
                    // Stop is gated on the minimum sample length, so there has to be a way out.
                    Button("Cancel") { cancelRecording() }
                } else {
                    Button("Record") { startRecording() }
                        .disabled(isBusy)
                }
                if isBusy {
                    ProgressView().controlSize(.small)
                    // Training can take up to two minutes; don't trap the tab until then.
                    Button("Cancel") { uploadTask?.cancel() }
                }
                Spacer()
                // Hidden while recording: previewing plays TTS out the speakers, which the
                // mic would capture into the sample we're about to upload.
                if !settings.clonedVoiceReferenceID.isEmpty && !isBusy && !recorder.isRecording {
                    Button("Preview") { preview() }
                }
            }

            if recorder.isRecording && recorder.elapsed < minimumCloneSeconds {
                Text("Keep going — \(Int(minimumCloneSeconds - recorder.elapsed))s more.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !settings.clonedVoiceReferenceID.isEmpty {
                Text("Cloned voice saved ✓ — the agent will speak with it.")
                    .font(.caption).foregroundStyle(.green)
            }
            if !statusText.isEmpty {
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func startRecording() {
        Task {
            guard await AudioRecorder.requestMicPermission() else {
                statusText = "Microphone permission denied. Grant it in System Settings → Privacy & Security → Microphone."
                return
            }
            do {
                try recorder.startRecording()
                statusText = ""
            } catch {
                statusText = error.localizedDescription
            }
        }
    }

    private func cancelRecording() {
        if let url = recorder.stopRecording() {
            try? FileManager.default.removeItem(at: url)
        }
        statusText = "Recording discarded."
    }

    private func stopAndUpload() {
        guard let url = recorder.stopRecording() else { return }
        guard let apiKey = KeychainStore.fishAPIKey.value else {
            statusText = "Set your Fish Audio API key in Settings first."
            try? FileManager.default.removeItem(at: url)
            return
        }

        isBusy = true
        statusText = "Uploading sample…"
        uploadTask = Task {
            defer { isBusy = false; uploadTask = nil; try? FileManager.default.removeItem(at: url) }
            do {
                let wavData = try Data(contentsOf: url)
                let client = FishAudioClient(apiKey: apiKey)
                let voice = try await client.createVoice(
                    title: "My Cloned Voice",
                    wavData: wavData,
                    transcriptText: clonePromptSentence
                )
                // A freshly created model can still be training; using it as a reference_id
                // before it reports "trained" fails, so wait it out here.
                if !voice.isUsable {
                    statusText = "Training the clone…"
                    try await client.waitUntilTrained(id: voice.id)
                }
                settings.clonedVoiceReferenceID = voice.id
                statusText = "Voice cloned successfully."
            } catch where error.isCancellation {
                statusText = "Cancelled. The voice may still finish training in your Fish Audio account."
            } catch {
                statusText = error.localizedDescription
            }
        }
    }

    private func preview() {
        guard let apiKey = KeychainStore.fishAPIKey.value else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                let audio = try await FishAudioClient(apiKey: apiKey).tts(
                    text: "This is what my cloned voice sounds like.",
                    referenceId: settings.clonedVoiceReferenceID
                )
                let p = try AVAudioPlayer(data: audio)
                player = p
                p.play()
            } catch {
                statusText = error.localizedDescription
            }
        }
    }
}
