import Foundation

@MainActor
final class CallTranscriber: ObservableObject {
    /// Shared so the transcript survives closing and reopening the window — otherwise a
    /// @StateObject would be recreated and the text lost before it could be saved.
    static let shared = CallTranscriber()

    struct Line: Identifiable {
        let id = UUID()
        let text: String
        let timestamp: Date
    }

    @Published var lines: [Line] = []
    @Published var isRunning = false
    @Published var statusText = ""

    private let capture = SystemAudioCapture()
    private var chunks: AsyncStream<Data>.Continuation?
    private var consumer: Task<Void, Never>?

    private init() {}

    func start() {
        guard !isRunning else { return }
        guard let apiKey = KeychainStore.fishAPIKey.value else {
            statusText = "Set your Fish Audio API key in Settings first."
            return
        }

        let client = FishAudioClient(apiKey: apiKey)

        // Chunks are transcribed strictly one at a time. Spawning a Task per chunk instead
        // would let slow ASR calls overlap, append lines out of chronological order, and turn
        // one rate-limit response into a cascade across every queued chunk. The bounded
        // buffer also caps how far behind we can fall.
        let (stream, continuation) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(8))
        chunks = continuation
        consumer = Task { @MainActor [weak self] in
            for await wav in stream {
                guard let self, self.isRunning else { continue }
                do {
                    let text = try await client.asr(wavData: wav).text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    self.lines.append(Line(text: text, timestamp: Date()))
                    // A line got through, so whatever we last complained about is stale.
                    self.statusText = ""
                } catch where error.isCancellation {
                    continue // Stop was pressed mid-request; stop() already cleared the status.
                } catch {
                    self.statusText = "Transcription error: \(error.localizedDescription)"
                }
            }
        }

        capture.onChunk = { [weak self] wav in
            guard let continuation = self?.chunks else { return }
            if case .dropped = continuation.yield(wav) {
                Task { @MainActor [weak self] in
                    self?.statusText = "Transcription fell behind — some audio was skipped."
                }
            }
        }
        capture.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.finish()
                self?.statusText = "Capture stopped: \(error.localizedDescription)"
            }
        }

        // Mark running up front so a double-tap can't start two streams while this awaits.
        isRunning = true
        statusText = "Starting capture…"
        Task {
            do {
                try await capture.start()
                // Chunks are 8–12s, so an empty window for the first ~10s is normal and
                // otherwise indistinguishable from a dead capture. Cleared by the first line.
                if statusText == "Starting capture…" {
                    statusText = "Listening… first line appears after ~10s of speech."
                }
            } catch {
                finish()
                statusText = error.localizedDescription
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        finish()
        statusText = ""
        Task { await capture.stop() }
    }

    private func finish() {
        isRunning = false
        chunks?.finish()
        chunks = nil
        consumer?.cancel()
        consumer = nil
    }

    func exportText() -> String {
        lines.map { line in
            let time = DateFormatter.localizedString(from: line.timestamp, dateStyle: .none, timeStyle: .medium)
            return "[\(time)] \(line.text)"
        }.joined(separator: "\n")
    }

    func clear() {
        lines.removeAll()
        statusText = ""
    }
}
