import AVFoundation

enum AudioRecorderError: Error, LocalizedError {
    case couldNotStart
    case noInputDevice

    var errorDescription: String? {
        switch self {
        case .couldNotStart: return "Could not start recording. Check the microphone in System Settings."
        case .noInputDevice: return "No microphone input device available."
        }
    }
}

/// Mic capture. Two modes sharing one type: fixed-duration record-to-file for voice
/// cloning, and RMS-gated utterance capture for the voice agent's turn taking.
final class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var outputURL: URL?

    private var engine: AVAudioEngine?

    static func requestMicPermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Fixed-duration capture (voice cloning)

    /// 44.1kHz mono 16-bit — plenty for cloning, and a format Fish Audio accepts directly.
    private static let wavSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: 44_100,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
    ]

    func startRecording() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let recorder = try AVAudioRecorder(url: url, settings: Self.wavSettings)
        guard recorder.record() else { throw AudioRecorderError.couldNotStart }
        self.recorder = recorder
        self.outputURL = url
        self.isRecording = true
        self.elapsed = 0
        // Read the recorder's own clock rather than accumulating ticks: Timer fires late under
        // load, and `elapsed` gates the minimum sample length the clone API needs.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.elapsed = recorder.currentTime
        }
    }

    /// Returns the recorded file's URL, or nil if nothing was recording.
    func stopRecording() -> URL? {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        isRecording = false
        defer { outputURL = nil }
        return outputURL
    }

    // MARK: - Utterance capture (voice agent turn taking)

    /// Starts listening; calls `onUtterance` with a WAV of the finished utterance once
    /// ~0.8s of silence follows detected speech. No VAD dependency — an RMS threshold is
    /// plenty for a demo. Bails out at `maxSeconds` so a stuck-open mic can't grow unbounded.
    ///
    /// Samples are accumulated in memory and encoded with `PCM.wavData` rather than written
    /// through AVAudioFile: the tap's format is whatever the device provides, and AVAudioFile
    /// rejects writes whose format doesn't match its processing format — which would have
    /// silently produced an empty WAV.
    func startListeningForUtterance(maxSeconds: TimeInterval = 30, onUtterance: @escaping (Data, Double) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Reduces the agent hearing its own TTS through the mic. Must precede reading the format.
        try? input.setVoiceProcessingEnabled(true)

        let tapFormat = input.outputFormat(forBus: 0)
        let sampleRate = tapFormat.sampleRate
        guard sampleRate > 0, tapFormat.channelCount > 0 else { throw AudioRecorderError.noInputDevice }

        var samples: [Float] = []
        var hasSpeech = false
        var silenceStart: Date?
        var finished = false
        let maxFrames = Int(maxSeconds * sampleRate)
        let silenceThreshold: Float = 0.015
        let silenceDuration: TimeInterval = 0.8

        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { [weak self] buffer, _ in
            guard !finished, let mono = PCM.monoSamples(from: buffer) else { return }
            samples.append(contentsOf: mono)

            if PCM.rms(mono) > silenceThreshold {
                hasSpeech = true
                silenceStart = nil
            } else if hasSpeech, silenceStart == nil {
                silenceStart = Date()
            }

            // Nothing but silence for maxSeconds: drop it and keep listening rather than pay
            // for an ASR call on a stuck-open mic.
            if !hasSpeech && samples.count >= maxFrames {
                samples.removeAll(keepingCapacity: true)
                return
            }

            let silentLongEnough = hasSpeech && (silenceStart.map { Date().timeIntervalSince($0) > silenceDuration } ?? false)
            guard silentLongEnough || samples.count >= maxFrames else { return }

            finished = true
            // Dispatching here establishes the happens-before edge for `samples`, which is
            // only written on this audio thread and only read after `finished` is set.
            let captured = samples
            DispatchQueue.main.async {
                self?.stopListening()
                onUtterance(PCM.wavData(from: captured, sampleRate: sampleRate), Double(captured.count) / sampleRate)
            }
        }

        try engine.start()
        self.engine = engine
    }

    func stopListening() {
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
    }
}
