import AVFoundation

// MARK: - Protocol

protocol TextToSpeechService: AnyObject, Sendable {
    func speak(_ text: String, senderRole: String?) async
    func stopSpeaking() async
    func setEnabled(_ enabled: Bool) async
    var isEnabled: Bool { get async }
}

// MARK: - AVSpeechSynthesizer implementation

actor AVSpeechTextToSpeechService: TextToSpeechService {
    private var enabled: Bool
    private var pendingUtterances: [(text: String, senderRole: String?)] = []
    private var isSpeaking = false

    private static let enabledKey = "TacNet.TTS.enabled"

    init(enabled: Bool? = nil) {
        self.enabled = enabled ?? UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var isEnabled: Bool { enabled }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    }

    func speak(_ text: String, senderRole: String?) async {
        guard enabled else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        pendingUtterances.append((text: trimmed, senderRole: senderRole))
        await processQueue()
    }

    func stopSpeaking() async {
        pendingUtterances.removeAll()
        isSpeaking = false
        await MainActor.run { TTSEngine.shared.stop() }
    }

    private func processQueue() async {
        guard !isSpeaking, let next = pendingUtterances.first else { return }
        pendingUtterances.removeFirst()
        isSpeaking = true

        let utteranceText: String
        if let role = next.senderRole, !role.isEmpty {
            utteranceText = "\(role) reports: \(next.text)"
        } else {
            utteranceText = next.text
        }

        await MainActor.run { TTSEngine.shared.speakSync(utteranceText) }
        await TTSEngine.shared.waitForCompletion()
        isSpeaking = false
        await processQueue()
    }
}

// MARK: - MainActor engine wrapping AVSpeechSynthesizer

@MainActor
final class TTSEngine: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSEngine()

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var completionContinuation: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speakSync(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.45
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.1
        synthesizer.speak(utterance)
    }

    func waitForCompletion() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            if !synthesizer.isSpeaking {
                continuation.resume()
                return
            }
            self.completionContinuation = continuation
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        completionContinuation?.resume()
        completionContinuation = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.completionContinuation?.resume()
            self.completionContinuation = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.completionContinuation?.resume()
            self.completionContinuation = nil
        }
    }
}
