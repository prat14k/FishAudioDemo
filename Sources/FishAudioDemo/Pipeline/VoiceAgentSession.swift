import Foundation
import AVFoundation

/// Orchestrates: mic utterance -> ASR -> AgentBrain -> TTS -> playback -> listen again.
/// No barge-in in v1 — the mic tap is torn down while speaking, so the loop is strictly
/// listen -> think -> speak -> listen.
@MainActor
final class VoiceAgentSession: ObservableObject {
    enum State: Equatable {
        case idle, listening, thinking, speaking
        case error(String)
    }

    @Published var state: State = .idle
    @Published var log: [String] = []

    private let recorder = AudioRecorder()
    private var player: AVAudioPlayer?
    private var history: [ChatMessage] = []
    /// The in-flight turn, so Stop can cancel its network calls instead of paying for a
    /// response nobody will hear.
    private var turn: Task<Void, Never>?
    /// Bumped on every stop, so a turn that finishes anyway can tell it's been cancelled.
    private var runID = UUID()

    /// An errored session is stopped, so the button offers Start again rather than Stop.
    var isRunning: Bool {
        switch state {
        case .idle, .error: return false
        case .listening, .thinking, .speaking: return true
        }
    }

    func start() {
        guard !isRunning else { return }
        let id = UUID()
        runID = id
        turn = Task {
            guard await AudioRecorder.requestMicPermission() else {
                guard runID == id else { return }
                state = .error("Microphone permission denied. Grant it in System Settings → Privacy & Security → Microphone.")
                return
            }
            guard runID == id, !Task.isCancelled else { return }
            listen(id)
        }
    }

    func stop() {
        runID = UUID()
        turn?.cancel()
        turn = nil
        recorder.stopListening()
        player?.stop()
        player = nil
        state = .idle
    }

    private func listen(_ id: UUID) {
        guard runID == id else { return }
        state = .listening
        do {
            try recorder.startListeningForUtterance { [weak self] wav, duration in
                self?.handleUtterance(wav, duration: duration, id)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func handleUtterance(_ wav: Data, duration: Double, _ id: UUID) {
        guard runID == id else { return }
        guard let apiKey = KeychainStore.fishAPIKey.value else {
            state = .error("Set your Fish Audio API key in Settings first.")
            return
        }
        // Too short to be speech — don't spend an API call on it.
        guard duration >= 0.4 else { listen(id); return }

        state = .thinking
        let settings = AppSettings.shared
        let brain = OpenAICompatibleBrain(
            baseURL: settings.brainBaseURL,
            model: settings.brainModel,
            apiKey: KeychainStore.brainAPIKey.value
        )
        let voiceID = settings.preferredVoiceReferenceID

        turn = Task {
            do {
                let client = FishAudioClient(apiKey: apiKey)
                let userText = try await client.asr(wavData: wav).text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard runID == id else { return }
                // Silence or noise that transcribed to nothing — just keep listening.
                guard !userText.isEmpty else { listen(id); return }
                log.append("You: \(userText)")

                let reply = try await brain.reply(to: userText, history: history)
                try Task.checkCancellation()
                guard runID == id else { return }
                if reply.isFailure {
                    log.append("⚠️ \(reply.text)")
                } else {
                    history.append(ChatMessage(role: "user", content: userText))
                    history.append(ChatMessage(role: "assistant", content: reply.text))
                    log.append("Agent: \(reply.text)")
                }

                let audio = try await client.tts(text: reply.text, referenceId: voiceID)
                try Task.checkCancellation()
                guard runID == id else { return }
                state = .speaking
                let p = try AVAudioPlayer(data: audio)
                player = p
                p.play()
                try await Task.sleep(nanoseconds: UInt64((p.duration + 0.3) * 1_000_000_000))
                guard runID == id else { return }
                listen(id)
            } catch where error.isCancellation {
                return // Stop was pressed; stop() already reset state.
            } catch {
                guard runID == id else { return }
                state = .error(error.localizedDescription)
            }
        }
    }
}
