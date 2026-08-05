import AVFoundation

/// Shared PCM helpers for both capture paths (mic utterances and system audio).
/// Keeping one implementation means one place to get the awkward parts right:
/// interleaved vs non-interleaved layouts, Float32 vs Int16 taps, and WAV framing.
enum PCM {
    /// Averages all channels into mono. Handles both interleaved and non-interleaved
    /// layouts — indexing `floatChannelData[c]` past channel 0 reads out of bounds on an
    /// interleaved buffer, where every channel is packed into one buffer instead — and
    /// both Float32 and Int16 taps, since the format is whatever the device hands us.
    static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frames = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frames > 0, channelCount > 0 else { return nil }
        let interleaved = buffer.format.isInterleaved

        if let channels = buffer.floatChannelData {
            return downmix(frames: frames, channelCount: channelCount, interleaved: interleaved) { c, f in
                interleaved ? channels[0][f * channelCount + c] : channels[c][f]
            }
        }
        if let channels = buffer.int16ChannelData {
            let scale = Float(Int16.max)
            return downmix(frames: frames, channelCount: channelCount, interleaved: interleaved) { c, f in
                Float(interleaved ? channels[0][f * channelCount + c] : channels[c][f]) / scale
            }
        }
        return nil
    }

    private static func downmix(frames: Int, channelCount: Int, interleaved: Bool, sample: (Int, Int) -> Float) -> [Float] {
        var mono = [Float](repeating: 0, count: frames)
        for f in 0..<frames {
            var sum: Float = 0
            for c in 0..<channelCount { sum += sample(c, f) }
            mono[f] = sum / Float(channelCount)
        }
        return mono
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples where s.isFinite { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Hand-rolled 16-bit mono WAV. ponytail: skips resampling down to 16kHz (uploads are
    /// larger than strictly necessary); revisit if upload bandwidth becomes a real problem.
    static func wavData(from samples: [Float], sampleRate: Double) -> Data {
        let sampleRateInt = UInt32(max(1, sampleRate))
        let dataSize = UInt32(samples.count * 2)

        var data = Data(capacity: 44 + samples.count * 2)
        func appendU32(_ v: UInt32) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 4)) }
        func appendU16(_ v: UInt16) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 2)) }

        data.append(Data("RIFF".utf8))
        appendU32(36 + dataSize)
        data.append(Data("WAVE".utf8))
        data.append(Data("fmt ".utf8))
        appendU32(16)
        appendU16(1)                 // PCM
        appendU16(1)                 // mono
        appendU32(sampleRateInt)
        appendU32(sampleRateInt * 2) // byte rate = rate * channels * bytesPerSample
        appendU16(2)                 // block align
        appendU16(16)                // bits per sample
        data.append(Data("data".utf8))
        appendU32(dataSize)
        for s in samples {
            // A non-finite sample would trap the Int16 conversion, so clamp NaN/inf to silence.
            let clamped = s.isFinite ? max(-1, min(1, s)) : 0
            appendU16(UInt16(bitPattern: Int16(clamped * 32767)))
        }
        return data
    }
}
