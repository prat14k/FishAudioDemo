import Foundation

/// Non-secret settings, persisted in UserDefaults. Secrets live in KeychainStore.
///
/// ponytail: plain @Published + didSet rather than @AppStorage. @AppStorage only publishes
/// changes when it's declared inside a View — inside a shared ObservableObject it silently
/// persists without notifying observers, so views never refresh.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var defaultVoiceReferenceID: String {
        didSet { defaults.set(defaultVoiceReferenceID, forKey: Key.defaultVoice) }
    }
    @Published var clonedVoiceReferenceID: String {
        didSet { defaults.set(clonedVoiceReferenceID, forKey: Key.clonedVoice) }
    }
    @Published var brainBaseURL: String {
        didSet { defaults.set(brainBaseURL, forKey: Key.brainBaseURL) }
    }
    @Published var brainModel: String {
        didSet { defaults.set(brainModel, forKey: Key.brainModel) }
    }

    private enum Key {
        static let defaultVoice = "defaultVoiceReferenceID"
        static let clonedVoice = "clonedVoiceReferenceID"
        static let brainBaseURL = "brainBaseURL"
        static let brainModel = "brainModel"
    }

    private init() {
        defaultVoiceReferenceID = defaults.string(forKey: Key.defaultVoice) ?? ""
        clonedVoiceReferenceID = defaults.string(forKey: Key.clonedVoice) ?? ""
        // Defaults to a local Ollama, which needs no API key.
        brainBaseURL = defaults.string(forKey: Key.brainBaseURL) ?? "http://localhost:11434/v1"
        brainModel = defaults.string(forKey: Key.brainModel) ?? "llama3.2"
    }

    /// The voice to speak agent replies with: the user's clone if they made one, else
    /// whichever sample voice they picked, else Fish Audio's default.
    var preferredVoiceReferenceID: String {
        clonedVoiceReferenceID.isEmpty ? defaultVoiceReferenceID : clonedVoiceReferenceID
    }
}
