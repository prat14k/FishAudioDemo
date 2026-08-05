import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreGraphics

enum SystemAudioCaptureError: Error, LocalizedError {
    case screenRecordingDenied
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .screenRecordingDenied:
            return "Screen Recording permission is required to capture call audio. Grant it in System Settings → Privacy & Security → Screen Recording, then relaunch the app."
        case .noDisplay:
            return "No display available to capture audio from."
        }
    }
}

/// Captures system audio output (what you hear — e.g. Meet/Zoom/Teams playback) via
/// ScreenCaptureKit, no virtual audio driver (BlackHole etc.) needed. Gated by the
/// Screen Recording TCC permission even though no video is involved.
///
/// Known v1 limitation: this captures the whole system audio mix (any app's sound),
/// not scoped to a specific call app, and only the "hear" side — not the user's own
/// mic speech. Documented, not solved here.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Emitted with a finished WAV chunk. Called on `queue`, not the main thread.
    var onChunk: ((Data) -> Void)?
    /// Emitted if the stream dies on its own (permission revoked, display disconnected).
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    /// All `samples`/`sampleRate` access is confined to this queue — it's both the
    /// sample-handler queue and where start/stop reset state, so there's no cross-thread access.
    private let queue = DispatchQueue(label: "com.bornwest.fishaudiodemo.audiocapture")
    private var samples: [Float] = []
    private var sampleRate: Double = 48_000

    /// Target chunk length, and the point past which we stop waiting for a quiet moment.
    private let chunkSeconds: Double = 8
    private let maxChunkSeconds: Double = 12
    /// Set by stop() so a stop racing an in-flight start() still tears the stream down.
    /// `stopRequested`/`stopTask`/`stream` are @MainActor-confined via start()/stop().
    private var stopRequested = false
    /// The in-flight teardown, if any. A fast stop→start would otherwise open a second
    /// SCStream while the first is still running, interleaving both into the same chunks.
    private var stopTask: Task<Void, Never>?

    @MainActor
    func start() async throws {
        await stopTask?.value
        stopRequested = false

        // Preflight so a denied permission gives a clear instruction instead of an opaque
        // SCShareableContent failure. CGRequestScreenCaptureAccess prompts and reports the
        // result directly, so trust its return rather than re-reading the preflight.
        if !CGPreflightScreenCaptureAccess(), !CGRequestScreenCaptureAccess() {
            throw SystemAudioCaptureError.screenRecordingDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw SystemAudioCaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true // keep our own TTS playback out of the transcript
        config.sampleRate = 48_000
        config.channelCount = 2
        // We add only an audio output, so no frames are consumed; throttle them rather than
        // shrinking the capture size, since undersized dimensions can fail startCapture.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        queue.sync { samples.removeAll() }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream

        // stop() may have been called while the above was awaiting; without this the stream
        // would keep capturing system audio forever with nothing listening.
        if stopRequested {
            await stop()
        }
    }

    @MainActor
    func stop() async {
        stopRequested = true
        // The task is stored in stopTask, so capturing self strongly would close a cycle.
        // The stream is held locally instead, so teardown still happens either way.
        let stream = self.stream
        self.stream = nil
        let task = Task { @MainActor [weak self] in
            try? await stream?.stopCapture()
            guard let self else { return }
            queue.sync { self.samples.removeAll() }
        }
        stopTask = task
        await task.value
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else { return }
        pcm.frameLength = AVAudioFrameCount(numSamples)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(numSamples), into: pcm.mutableAudioBufferList) == noErr else { return }
        appendAndMaybeEmit(pcm)
    }

    /// Already on `queue` (the sample handler queue).
    private func appendAndMaybeEmit(_ buffer: AVAudioPCMBuffer) {
        guard let mono = PCM.monoSamples(from: buffer) else { return }

        // A rate change mid-chunk would leave the WAV header describing one rate and the
        // samples another, so close out what we have first.
        if buffer.format.sampleRate != sampleRate {
            emitPending()
            sampleRate = buffer.format.sampleRate
        }
        samples.append(contentsOf: mono)

        let target = Int(chunkSeconds * sampleRate)
        guard samples.count >= target else { return }
        // Prefer to cut on a quiet buffer so a word isn't sliced in half mid-sentence, but
        // don't wait forever for silence on a continuously noisy call.
        let quiet = PCM.rms(mono) < 0.01
        guard quiet || samples.count >= Int(maxChunkSeconds * sampleRate) else { return }
        emitPending()
    }

    private func emitPending() {
        guard !samples.isEmpty else { return }
        let chunk = samples
        samples.removeAll(keepingCapacity: true)
        onChunk?(PCM.wavData(from: chunk, sampleRate: sampleRate))
    }
}
