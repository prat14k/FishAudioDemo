import Foundation

enum FishAudioModel: String {
    case pro = "s2.1-pro"
    case proFree = "s2.1-pro-free"
}

enum FishAudioError: Error, LocalizedError {
    case httpError(status: Int, body: String)
    case cloneFailed
    case cloneTimedOut

    var errorDescription: String? {
        switch self {
        case .httpError(let status, let body):
            let detail = body.isEmpty ? "" : " — \(body.prefix(300))"
            switch status {
            case 401: return "Fish Audio rejected the API key (401). Check it in Settings.\(detail)"
            case 402: return "Fish Audio says payment/credit required (402).\(detail)"
            case 429: return "Rate limited by Fish Audio (429). Wait a moment and retry.\(detail)"
            default: return "Fish Audio API error \(status)\(detail)"
            }
        case .cloneFailed: return "Fish Audio reported the voice clone failed to train."
        case .cloneTimedOut: return "Voice clone is still training — check back shortly."
        }
    }
}

extension Error {
    /// URLSession throws `URLError(.cancelled)` — not `CancellationError` — when the task it's
    /// bridging gets cancelled, so a bare `catch is CancellationError` misses real cancellations
    /// and reports them as "error -999" instead.
    var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}

/// Thin wrapper over Fish Audio's REST API, written against their published OpenAPI spec
/// (https://api.fish.audio/openapi.json). URLSession covers JSON + multipart; no
/// third-party HTTP dependency needed.
final class FishAudioClient {
    private let apiKey: String
    private let session: URLSession = .shared
    private let base = URL(string: "https://api.fish.audio")!

    init(apiKey: String) {
        // Pasted keys routinely carry a trailing newline/space; that would corrupt the
        // Authorization header and come back as an opaque 401.
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func authedRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return req
    }

    private static func checkStatus(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FishAudioError.httpError(status: status, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - Text to Speech  (POST /v1/tts)

    private struct Prosody: Encodable { let speed: Double }
    private struct TTSRequestBody: Encodable {
        let text: String
        var reference_id: String?
        var format: String = "mp3"
        var prosody: Prosody?
    }

    /// Returns raw audio bytes (mp3) — hand straight to AVAudioPlayer.
    func tts(text: String, referenceId: String? = nil, speed: Double = 1.0, model: FishAudioModel = .proFree) async throws -> Data {
        var req = authedRequest(url: base.appendingPathComponent("v1/tts"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(model.rawValue, forHTTPHeaderField: "model")
        // Empty-string reference ids must become nil, or the API looks up a voice named "".
        let ref = (referenceId?.isEmpty ?? true) ? nil : referenceId
        let body = TTSRequestBody(text: text, reference_id: ref, prosody: Prosody(speed: speed))
        req.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: req)
        try Self.checkStatus(response, data)
        return data
    }

    // MARK: - Speech to Text  (POST /v1/asr)

    struct ASRSegment: Decodable { let text: String; let start: Double; let end: Double }
    struct ASRResponse: Decodable {
        let text: String
        var duration: Double = 0
        var segments: [ASRSegment] = []

        private enum CodingKeys: String, CodingKey { case text, duration, segments }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            duration = (try? c.decode(Double.self, forKey: .duration)) ?? 0
            segments = (try? c.decode([ASRSegment].self, forKey: .segments)) ?? []
        }
    }

    func asr(wavData: Data, language: String? = nil) async throws -> ASRResponse {
        var req = authedRequest(url: base.appendingPathComponent("v1/asr"))
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // ignore_timestamps=true is the API default and skips segment timing work we don't use.
        var fields: [String: String] = ["ignore_timestamps": "true"]
        if let language { fields["language"] = language }
        req.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: fields,
            files: [(field: "audio", filename: "chunk.wav", data: wavData, mimeType: "audio/wav")]
        )

        let (data, response) = try await session.data(for: req)
        try Self.checkStatus(response, data)
        return try JSONDecoder().decode(ASRResponse.self, from: data)
    }

    // MARK: - Voice models  (POST /model, GET /model, GET /model/{id})

    struct VoiceItem: Decodable, Identifiable {
        let id: String
        let title: String
        let state: String

        private enum CodingKeys: String, CodingKey { case id = "_id", title, state }

        /// Only `trained` models can be used as a TTS reference_id.
        var isUsable: Bool { state == "trained" }
    }
    private struct VoiceListResponse: Decodable { let items: [VoiceItem] }

    /// Creates a saved voice model from a sample clip. Returns the new model's id.
    /// The model may still be training when this returns — see `waitUntilTrained`.
    func createVoice(title: String, wavData: Data, transcriptText: String) async throws -> VoiceItem {
        var req = authedRequest(url: base.appendingPathComponent("model"))
        req.httpMethod = "POST"
        let boundary = "Boundary-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(
            boundary: boundary,
            fields: [
                "type": "tts",
                "title": title,
                // The API defaults visibility to "public" — never publish someone's cloned
                // voice to the community library by omission.
                "visibility": "private",
                "train_mode": "fast",
                "texts": transcriptText,
            ],
            files: [(field: "voices", filename: "sample.wav", data: wavData, mimeType: "audio/wav")]
        )

        let (data, response) = try await session.data(for: req)
        try Self.checkStatus(response, data)
        return try JSONDecoder().decode(VoiceItem.self, from: data)
    }

    func voice(id: String) async throws -> VoiceItem {
        let req = authedRequest(url: base.appendingPathComponent("model/\(id)"))
        let (data, response) = try await session.data(for: req)
        try Self.checkStatus(response, data)
        return try JSONDecoder().decode(VoiceItem.self, from: data)
    }

    /// Polls until the model reports `trained`, so a freshly cloned voice is never handed
    /// to TTS while it would still 4xx.
    func waitUntilTrained(id: String, timeout: TimeInterval = 120) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let voice = try await self.voice(id: id)
            switch voice.state {
            case "trained": return
            case "failed": throw FishAudioError.cloneFailed
            default: try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        throw FishAudioError.cloneTimedOut
    }

    /// A handful of usable public voices for the browse tab. Fetched live rather than
    /// hardcoded — community model ids come and go — and filtered to trained models,
    /// since anything else fails when used as a reference_id.
    func listPublicVoices(limit: Int = 8) async throws -> [VoiceItem] {
        var comps = URLComponents(url: base.appendingPathComponent("model"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "self", value: "false"),
            URLQueryItem(name: "sort_by", value: "task_count"), // most-used first: reliable samples
            URLQueryItem(name: "page_size", value: String(limit * 2)),
            URLQueryItem(name: "page_number", value: "1"),
        ]
        let req = authedRequest(url: comps.url!)
        let (data, response) = try await session.data(for: req)
        try Self.checkStatus(response, data)
        let items = try JSONDecoder().decode(VoiceListResponse.self, from: data).items
        return Array(items.filter(\.isUsable).prefix(limit))
    }

    // MARK: - Multipart helper

    struct FilePart {
        let field: String
        let filename: String
        let data: Data
        let mimeType: String
    }

    static func multipartBody(boundary: String, fields: [String: String], files: [FilePart]) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }

        for (name, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        for file in files {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(file.field)\"; filename=\"\(file.filename)\"\r\n")
            append("Content-Type: \(file.mimeType)\r\n\r\n")
            body.append(file.data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    static func multipartBody(boundary: String, fields: [String: String], files: [(field: String, filename: String, data: Data, mimeType: String)]) -> Data {
        multipartBody(boundary: boundary, fields: fields, files: files.map {
            FilePart(field: $0.field, filename: $0.filename, data: $0.data, mimeType: $0.mimeType)
        })
    }
}
