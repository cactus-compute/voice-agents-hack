import Foundation
import Combine
import CoreBluetooth
import AVFoundation

struct BluetoothMeshUUIDs {
    static let service = CBUUID(string: "7B4D8C10-3A8E-4D1A-9F53-2E28D9C1A001")
    static let broadcastCharacteristic = CBUUID(string: "7B4D8C10-3A8E-4D1A-9F53-2E28D9C1A101")
    static let compactionCharacteristic = CBUUID(string: "7B4D8C10-3A8E-4D1A-9F53-2E28D9C1A102")
    static let treeConfigCharacteristic = CBUUID(string: "7B4D8C10-3A8E-4D1A-9F53-2E28D9C1A103")
}

struct RecordedAudioClip: Sendable, Equatable {
    let data: Data
    let sampleRate: Int
    let channels: Int
    let bitsPerSample: Int

    var isPCM16kMono16Bit: Bool {
        sampleRate == 16_000 &&
            channels == 1 &&
            bitsPerSample == 16 &&
            data.count.isMultiple(of: MemoryLayout<Int16>.size)
    }

    var bytesPerSecond: Int {
        sampleRate * channels * bitsPerSample / 8
    }

    var durationSeconds: TimeInterval {
        guard bytesPerSecond > 0 else {
            return 0
        }
        return TimeInterval(Double(data.count) / Double(bytesPerSecond))
    }

    func capped(to maximumDuration: TimeInterval) -> RecordedAudioClip {
        guard maximumDuration > 0, bytesPerSecond > 0 else {
            return self
        }

        let maximumBytes = Int(Double(bytesPerSecond) * maximumDuration)
        guard data.count > maximumBytes else {
            return self
        }

        return RecordedAudioClip(
            data: Data(data.prefix(maximumBytes)),
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample
        )
    }

    func hasSpeech(amplitudeThreshold: Int16 = 500, minimumActiveSamples: Int = 160) -> Bool {
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size),
              minimumActiveSamples > 0 else {
            return false
        }

        let threshold = abs(Int(amplitudeThreshold))
        var activeSamples = 0
        var peakAmplitude = 0
        data.withUnsafeBytes { rawBuffer in
            let samples = rawBuffer.bindMemory(to: Int16.self)
            for sample in samples {
                let amplitude = abs(Int(sample))
                if amplitude > peakAmplitude { peakAmplitude = amplitude }
                if amplitude >= threshold {
                    activeSamples += 1
                    if activeSamples >= minimumActiveSamples {
                        break
                    }
                }
            }
        }
        let detected = activeSamples >= minimumActiveSamples
        NSLog("[Audio] Speech check — peak amplitude: %d, active samples: %d/%d, threshold: %d → %@",
              peakAmplitude, activeSamples, minimumActiveSamples, threshold,
              detected ? "SPEECH" : "SILENCE")
        return detected
    }
}

enum AudioServiceError: Error, Equatable {
    case alreadyRecording
    case notRecording
    case invalidAudioFormat
    case captureFailed(String)
}

protocol AudioCapturing: Sendable {
    func startCapture() async throws
    func stopCapture() async throws -> RecordedAudioClip
}

protocol CactusTranscribing: Sendable {
    func transcribePCM16kMono(_ pcmData: Data) async throws -> String
}

protocol TranscriptConsuming: Sendable {
    func receiveTranscript(_ transcript: AudioService.TranscriptResult) async
}

actor CactusTranscriber: CactusTranscribing {
    typealias TranscribeFunction = @Sendable (CactusModelT, Data) throws -> String

    private let modelHandleProvider: any ModelHandleProviding
    private let transcribeFunction: TranscribeFunction

    init(
        modelHandleProvider: any ModelHandleProviding = BundledModelInitializationService.parakeet,
        transcribeFunction: @escaping TranscribeFunction = { model, pcmData in
            try cactusTranscribe(model, nil, nil, nil, nil, pcmData)
        }
    ) {
        self.modelHandleProvider = modelHandleProvider
        self.transcribeFunction = transcribeFunction
    }

    func transcribePCM16kMono(_ pcmData: Data) async throws -> String {
        NSLog("[STT] Loading model via %@", String(describing: type(of: modelHandleProvider)))
        let modelHandle = try await modelHandleProvider.provideModelHandle()
        NSLog("[STT] Model handle acquired, transcribing %d bytes of PCM audio", pcmData.count)
        let responseJSON = try transcribeFunction(modelHandle, pcmData)
        NSLog("[STT] Raw response: %@", responseJSON.prefix(200).description)
        return Self.extractTranscript(from: responseJSON)
    }

    private static func extractTranscript(from response: String) -> String {
        let trimmedResponse = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedResponse.isEmpty else {
            return ""
        }

        guard let payload = trimmedResponse.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: payload) else {
            return trimmedResponse
        }

        guard let rootObject = json as? [String: Any] else {
            return trimmedResponse
        }

        if let transcript = firstNonEmptyTranscript(in: rootObject) {
            return transcript
        }

        if let nested = rootObject["result"] as? [String: Any],
           let transcript = firstNonEmptyTranscript(in: nested) {
            return transcript
        }

        if let nestedArray = rootObject["results"] as? [[String: Any]] {
            for item in nestedArray {
                if let transcript = firstNonEmptyTranscript(in: item) {
                    return transcript
                }
            }
        }

        return trimmedResponse
    }

    private static func firstNonEmptyTranscript(in object: [String: Any]) -> String? {
        for key in ["transcript", "response", "text"] {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

protocol TacticalSummarizing: Sendable {
    func summarize(systemPrompt: String, userPrompt: String) async throws -> String
}

actor CactusTacticalSummarizer: TacticalSummarizing {
    typealias CompleteFunction = @Sendable (
        CactusModelT,
        String,
        String?,
        String?,
        ((String, UInt32) -> Void)?,
        Data?
    ) throws -> String

    private struct PromptMessage: Codable {
        let role: String
        let content: String
    }

    private let modelInitializationService: CactusModelInitializationService
    private let completeFunction: CompleteFunction
    private let optionsJSON: String

    init(
        modelInitializationService: CactusModelInitializationService = .shared,
        completeFunction: @escaping CompleteFunction = { model, messages, options, tools, onToken, pcm in
            try cactusComplete(model, messages, options, tools, onToken, pcm)
        },
        optionsJSON: String = #"{"max_tokens":96,"temperature":0.0}"#
    ) {
        self.modelInitializationService = modelInitializationService
        self.completeFunction = completeFunction
        self.optionsJSON = optionsJSON
    }

    func summarize(systemPrompt: String, userPrompt: String) async throws -> String {
        let modelHandle = try await modelInitializationService.initializeModelAfterEnsuringDownload()
        let messagesJSON = try Self.messagesJSON(systemPrompt: systemPrompt, userPrompt: userPrompt)
        let completion = try completeFunction(modelHandle, messagesJSON, optionsJSON, nil, nil, nil)
        return Self.extractSummary(from: completion)
    }

    private static func messagesJSON(systemPrompt: String, userPrompt: String) throws -> String {
        let payload = [
            PromptMessage(role: "system", content: systemPrompt),
            PromptMessage(role: "user", content: userPrompt)
        ]
        let data = try JSONEncoder().encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func extractSummary(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return trimmed
        }

        if let responseValue = firstNonEmptyValue(for: ["response", "summary", "text"], in: json) {
            return responseValue
        }

        if let nestedResult = json["result"] as? [String: Any],
           let responseValue = firstNonEmptyValue(for: ["response", "summary", "text"], in: nestedResult) {
            return responseValue
        }

        return trimmed
    }

    private static func firstNonEmptyValue(for keys: [String], in object: [String: Any]) -> String? {
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

actor CompactionEngine {
    enum TriggerReason: String, Equatable, Sendable {
        case timeWindow
        case messageCount
        case priorityKeyword
        case manual
    }

    enum ProcessingStatus: String, Equatable, Sendable {
        case idle
        case compacting
    }

    struct Configuration: Equatable, Sendable {
        var timeWindow: TimeInterval
        var messageCountThreshold: Int
        var defaultTTL: Int

        init(
            timeWindow: TimeInterval = 8,
            messageCountThreshold: Int = 5,
            defaultTTL: Int = 8
        ) {
            self.timeWindow = max(0, timeWindow)
            self.messageCountThreshold = max(1, messageCountThreshold)
            self.defaultTTL = max(1, defaultTTL)
        }
    }

    struct ProcessingMetrics: Equatable, Sendable {
        let status: ProcessingStatus
        let triggerReason: TriggerReason?
        let latencyMilliseconds: Double?
        let inputTokenCount: Int
        let outputTokenCount: Int
        let compressionRatio: Double?
        let sourceMessageCount: Int
        let updatedAt: Date

        static func idle(updatedAt: Date) -> ProcessingMetrics {
            ProcessingMetrics(
                status: .idle,
                triggerReason: nil,
                latencyMilliseconds: nil,
                inputTokenCount: 0,
                outputTokenCount: 0,
                compressionRatio: nil,
                sourceMessageCount: 0,
                updatedAt: updatedAt
            )
        }
    }

    struct CompactionEmission: Equatable, Sendable {
        let message: Message
        let triggerReason: TriggerReason
        let sourceMessageCount: Int
        let sourceNodeIDs: [String]
        let destinationNodeID: String?
        let outputText: String
        let summaryWordCount: Int
        let inputTokenCount: Int
        let outputTokenCount: Int
        let compressionRatio: Double
        let latencyMilliseconds: Double
        let generatedAt: Date
    }

    struct SITREP: Equatable, Sendable {
        let text: String
        let triggerReason: TriggerReason
        let sourceMessageCount: Int
        let generatedAt: Date
    }

    typealias ProcessingObserver = @Sendable (ProcessingMetrics) -> Void
    typealias CompactionEmissionObserver = @Sendable (CompactionEmission) -> Void

    private struct QueueItem: Sendable {
        let body: String
        let sourceNodeID: String
        let receivedAt: Date
    }

    private let localDeviceID: String
    private let localNodeID: String
    private let localSenderRole: String
    private let messageRouter: MessageRouter
    private let summarizer: any TacticalSummarizing
    private let configuration: Configuration
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (UInt64) async -> Void

    private var tree: TreeNode

    private var queuedChildTranscripts: [QueueItem] = []
    private var queuedL1Compactions: [QueueItem] = []

    private var childCompactionTimerTask: Task<Void, Never>?
    private var sitrepTimerTask: Task<Void, Never>?

    private var compactionEmissionsStorage: [CompactionEmission] = []
    private var latestSitrepStorage: SITREP?
    private var processingMetricsStorage: ProcessingMetrics = .idle(updatedAt: .distantPast)
    private var processingObserver: ProcessingObserver?
    private var compactionEmissionObserver: CompactionEmissionObserver?

    init(
        localDeviceID: String,
        localNodeID: String,
        localSenderRole: String,
        initialTree: TreeNode,
        messageRouter: MessageRouter = MessageRouter(),
        summarizer: any TacticalSummarizing = CactusTacticalSummarizer(),
        configuration: Configuration = Configuration(),
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (UInt64) async -> Void = { nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        }
    ) {
        self.localDeviceID = localDeviceID
        self.localNodeID = localNodeID
        self.localSenderRole = localSenderRole
        self.tree = initialTree
        self.messageRouter = messageRouter
        self.summarizer = summarizer
        self.configuration = configuration
        self.now = now
        self.sleep = sleep
        processingMetricsStorage = .idle(updatedAt: self.now())
    }

    deinit {
        childCompactionTimerTask?.cancel()
        sitrepTimerTask?.cancel()
    }

    func updateTree(_ tree: TreeNode) {
        self.tree = tree
    }

    func enqueueChildTranscript(_ transcript: String, from childNodeID: String) async {
        guard isDirectChild(nodeID: childNodeID) else {
            return
        }

        let normalizedTranscript = normalizedInput(transcript)
        guard !normalizedTranscript.isEmpty else {
            return
        }

        queuedChildTranscripts.append(
            QueueItem(body: normalizedTranscript, sourceNodeID: childNodeID, receivedAt: now())
        )

        if Self.containsPriorityKeyword(in: normalizedTranscript) {
            await triggerChildCompaction(reason: .priorityKeyword)
            return
        }

        if queuedChildTranscripts.count >= configuration.messageCountThreshold {
            await triggerChildCompaction(reason: .messageCount)
            return
        }

        scheduleChildCompactionTimerIfNeeded()
    }

    func enqueueL1CompactionSummary(_ summary: String, from childNodeID: String) async {
        guard isRootNode, isDirectChild(nodeID: childNodeID) else {
            return
        }

        let normalizedSummary = normalizedInput(summary)
        guard !normalizedSummary.isEmpty else {
            return
        }

        queuedL1Compactions.append(
            QueueItem(body: normalizedSummary, sourceNodeID: childNodeID, receivedAt: now())
        )

        if Self.containsPriorityKeyword(in: normalizedSummary) {
            await triggerSITREP(reason: .priorityKeyword)
            return
        }

        if queuedL1Compactions.count >= configuration.messageCountThreshold {
            await triggerSITREP(reason: .messageCount)
            return
        }

        scheduleSITREPTimerIfNeeded()
    }

    func flushQueuedChildTranscripts() async {
        await triggerChildCompaction(reason: .manual)
    }

    func flushQueuedL1Compactions() async {
        await triggerSITREP(reason: .manual)
    }

    func emittedCompactions() -> [CompactionEmission] {
        compactionEmissionsStorage
    }

    func latestSITREP() -> SITREP? {
        latestSitrepStorage
    }

    func latestProcessingMetrics() -> ProcessingMetrics {
        processingMetricsStorage
    }

    func setProcessingObserver(_ observer: ProcessingObserver?) {
        processingObserver = observer
        observer?(processingMetricsStorage)
    }

    func setCompactionEmissionObserver(_ observer: CompactionEmissionObserver?) {
        compactionEmissionObserver = observer
    }

    private var isRootNode: Bool {
        TreeHelpers.level(of: localNodeID, in: tree) == 0
    }

    private func isDirectChild(nodeID: String) -> Bool {
        TreeHelpers.parent(of: nodeID, in: tree)?.id == localNodeID
    }

    private func scheduleChildCompactionTimerIfNeeded() {
        guard childCompactionTimerTask == nil, !queuedChildTranscripts.isEmpty else {
            return
        }

        let delayNanoseconds = Self.nanoseconds(from: configuration.timeWindow)
        childCompactionTimerTask = Task { [sleep] in
            await sleep(delayNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await self.handleChildCompactionTimerFired()
        }
    }

    private func scheduleSITREPTimerIfNeeded() {
        guard sitrepTimerTask == nil, !queuedL1Compactions.isEmpty else {
            return
        }

        let delayNanoseconds = Self.nanoseconds(from: configuration.timeWindow)
        sitrepTimerTask = Task { [sleep] in
            await sleep(delayNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await self.handleSITREPTimerFired()
        }
    }

    private func handleChildCompactionTimerFired() async {
        childCompactionTimerTask = nil
        guard !queuedChildTranscripts.isEmpty else {
            return
        }
        await triggerChildCompaction(reason: .timeWindow)
    }

    private func handleSITREPTimerFired() async {
        sitrepTimerTask = nil
        guard !queuedL1Compactions.isEmpty else {
            return
        }
        await triggerSITREP(reason: .timeWindow)
    }

    private func triggerChildCompaction(reason: TriggerReason) async {
        guard !queuedChildTranscripts.isEmpty else {
            return
        }

        childCompactionTimerTask?.cancel()
        childCompactionTimerTask = nil

        let queuedItems = queuedChildTranscripts
        queuedChildTranscripts.removeAll(keepingCapacity: true)

        guard let destinationNodeID = TreeHelpers.parent(of: localNodeID, in: tree)?.id else {
            return
        }

        let processingStartedAt = now()
        let inputTokenCount = Self.estimatedTokenCount(in: queuedItems.map(\.body).joined(separator: " "))
        updateProcessingMetrics(
            ProcessingMetrics(
                status: .compacting,
                triggerReason: reason,
                latencyMilliseconds: nil,
                inputTokenCount: inputTokenCount,
                outputTokenCount: 0,
                compressionRatio: nil,
                sourceMessageCount: queuedItems.count,
                updatedAt: processingStartedAt
            )
        )

        let summary = await summarizeChildTranscripts(queuedItems)
        let processingFinishedAt = now()
        let latencyMilliseconds = processingFinishedAt.timeIntervalSince(processingStartedAt) * 1_000
        let outputTokenCount = Self.estimatedTokenCount(in: summary)
        let compressionRatio = Self.compressionRatio(
            inputTokenCount: inputTokenCount,
            outputTokenCount: outputTokenCount
        )

        guard !summary.isEmpty else {
            updateProcessingMetrics(
                ProcessingMetrics(
                    status: .idle,
                    triggerReason: reason,
                    latencyMilliseconds: latencyMilliseconds,
                    inputTokenCount: inputTokenCount,
                    outputTokenCount: outputTokenCount,
                    compressionRatio: compressionRatio,
                    sourceMessageCount: queuedItems.count,
                    updatedAt: processingFinishedAt
                )
            )
            return
        }

        let timestamp = processingFinishedAt
        let compactionMessage = messageRouter.makeCompactionMessage(
            summary: summary,
            senderID: localDeviceID,
            senderNodeID: localNodeID,
            senderRole: localSenderRole,
            in: tree,
            ttl: configuration.defaultTTL,
            encrypted: false,
            timestamp: timestamp
        )

        compactionEmissionsStorage.append(
            CompactionEmission(
                message: compactionMessage,
                triggerReason: reason,
                sourceMessageCount: queuedItems.count,
                sourceNodeIDs: Self.uniqueSourceNodeIDs(from: queuedItems),
                destinationNodeID: destinationNodeID,
                outputText: summary,
                summaryWordCount: Self.wordCount(in: summary),
                inputTokenCount: inputTokenCount,
                outputTokenCount: outputTokenCount,
                compressionRatio: compressionRatio ?? 0,
                latencyMilliseconds: latencyMilliseconds,
                generatedAt: timestamp
            )
        )

        if let latestEmission = compactionEmissionsStorage.last {
            compactionEmissionObserver?(latestEmission)
        }

        updateProcessingMetrics(
            ProcessingMetrics(
                status: .idle,
                triggerReason: reason,
                latencyMilliseconds: latencyMilliseconds,
                inputTokenCount: inputTokenCount,
                outputTokenCount: outputTokenCount,
                compressionRatio: compressionRatio,
                sourceMessageCount: queuedItems.count,
                updatedAt: processingFinishedAt
            )
        )
    }

    private func triggerSITREP(reason: TriggerReason) async {
        guard !queuedL1Compactions.isEmpty else {
            return
        }

        sitrepTimerTask?.cancel()
        sitrepTimerTask = nil

        guard isRootNode else {
            queuedL1Compactions.removeAll(keepingCapacity: true)
            return
        }

        let queuedItems = queuedL1Compactions
        queuedL1Compactions.removeAll(keepingCapacity: true)

        let processingStartedAt = now()
        let inputTokenCount = Self.estimatedTokenCount(in: queuedItems.map(\.body).joined(separator: " "))
        updateProcessingMetrics(
            ProcessingMetrics(
                status: .compacting,
                triggerReason: reason,
                latencyMilliseconds: nil,
                inputTokenCount: inputTokenCount,
                outputTokenCount: 0,
                compressionRatio: nil,
                sourceMessageCount: queuedItems.count,
                updatedAt: processingStartedAt
            )
        )

        let sitrepText = await summarizeL1Compactions(queuedItems)
        let processingFinishedAt = now()
        let latencyMilliseconds = processingFinishedAt.timeIntervalSince(processingStartedAt) * 1_000
        let outputTokenCount = Self.estimatedTokenCount(in: sitrepText)
        let compressionRatio = Self.compressionRatio(
            inputTokenCount: inputTokenCount,
            outputTokenCount: outputTokenCount
        )

        guard !sitrepText.isEmpty else {
            updateProcessingMetrics(
                ProcessingMetrics(
                    status: .idle,
                    triggerReason: reason,
                    latencyMilliseconds: latencyMilliseconds,
                    inputTokenCount: inputTokenCount,
                    outputTokenCount: outputTokenCount,
                    compressionRatio: compressionRatio,
                    sourceMessageCount: queuedItems.count,
                    updatedAt: processingFinishedAt
                )
            )
            return
        }

        latestSitrepStorage = SITREP(
            text: sitrepText,
            triggerReason: reason,
            sourceMessageCount: queuedItems.count,
            generatedAt: processingFinishedAt
        )

        updateProcessingMetrics(
            ProcessingMetrics(
                status: .idle,
                triggerReason: reason,
                latencyMilliseconds: latencyMilliseconds,
                inputTokenCount: inputTokenCount,
                outputTokenCount: outputTokenCount,
                compressionRatio: compressionRatio,
                sourceMessageCount: queuedItems.count,
                updatedAt: processingFinishedAt
            )
        )
    }

    private func summarizeChildTranscripts(_ transcripts: [QueueItem]) async -> String {
        await summarize(
            entries: transcripts,
            systemPrompt: Self.compactionSystemPrompt,
            promptPrefix: "Summarize these child tactical transcripts into one update:"
        )
    }

    private func summarizeL1Compactions(_ compactions: [QueueItem]) async -> String {
        await summarize(
            entries: compactions,
            systemPrompt: Self.sitrepSystemPrompt,
            promptPrefix: "Produce a commander SITREP from these L1 compactions:"
        )
    }

    private func summarize(
        entries: [QueueItem],
        systemPrompt: String,
        promptPrefix: String
    ) async -> String {
        let numberedLines = entries.enumerated().map { index, item in
            "\(index + 1). \(item.body)"
        }.joined(separator: "\n")
        let userPrompt = "\(promptPrefix)\n\(numberedLines)"

        let generated: String
        do {
            generated = try await summarizer.summarize(systemPrompt: systemPrompt, userPrompt: userPrompt)
        } catch {
            generated = entries.map(\.body).joined(separator: " ")
        }

        return Self.sanitizeSummary(generated, maxWords: 30)
    }

    private func normalizedInput(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func updateProcessingMetrics(_ metrics: ProcessingMetrics) {
        processingMetricsStorage = metrics
        processingObserver?(metrics)
    }

    private static let compactionSystemPrompt = """
    You are TacNet's tactical summarizer.
    Preserve critical information: locations, threats, casualty details, and unit status.
    Remove filler language (uh, um, copy that, roger, say again, over).
    Return plain text only and keep the summary under 30 words.
    """

    private static let sitrepSystemPrompt = """
    You are TacNet's root SITREP summarizer.
    Preserve critical information: locations, threats, casualty details, and unit status from L1 compactions.
    Remove filler language (uh, um, copy that, roger, say again, over).
    Return plain text only and keep the SITREP under 30 words.
    """

    private static let priorityKeywordRegex: NSRegularExpression = {
        let pattern = #"(?<![A-Za-z0-9_])(contact|casualty|emergency)(?![A-Za-z0-9_])"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static let priorityFalsePositivePhraseRegex: NSRegularExpression = {
        let pattern = #"(?<![A-Za-z0-9_])(contact(?:\s|-)+lens|emergency(?:\s|-)+exit)(?![A-Za-z0-9_])"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private static func containsPriorityKeyword(in text: String) -> Bool {
        let sourceRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let phraseFilteredText = priorityFalsePositivePhraseRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: sourceRange,
            withTemplate: " "
        )
        let range = NSRange(phraseFilteredText.startIndex..<phraseFilteredText.endIndex, in: phraseFilteredText)
        return priorityKeywordRegex.firstMatch(in: phraseFilteredText, options: [], range: range) != nil
    }

    private static func sanitizeSummary(_ raw: String, maxWords: Int) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return ""
        }

        value = replacingMatches(#"(?i)\bcopy\s+that\b"#, in: value, with: " ")
        value = replacingMatches(#"(?i)\bsay\s+again\b"#, in: value, with: " ")
        value = replacingMatches(#"(?i)\b(?:uh+|um+|roger|over)\b"#, in: value, with: " ")
        value = replacingMatches(#"\s+"#, in: value, with: " ")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        let words = value.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else {
            return "No actionable update."
        }

        return words.prefix(max(1, maxWords)).joined(separator: " ")
    }

    private static func replacingMatches(_ pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, options: [], range: range, withTemplate: replacement)
    }

    private static func nanoseconds(from seconds: TimeInterval) -> UInt64 {
        let clamped = max(0, seconds)
        return UInt64(clamped * 1_000_000_000)
    }

    private static func estimatedTokenCount(in value: String) -> Int {
        wordCount(in: value)
    }

    private static func compressionRatio(inputTokenCount: Int, outputTokenCount: Int) -> Double? {
        guard inputTokenCount > 0 else {
            return nil
        }
        return Double(outputTokenCount) / Double(inputTokenCount)
    }

    private static func uniqueSourceNodeIDs(from queuedItems: [QueueItem]) -> [String] {
        var seen: Set<String> = []
        var orderedUniqueIDs: [String] = []

        for item in queuedItems where !item.sourceNodeID.isEmpty {
            if seen.insert(item.sourceNodeID).inserted {
                orderedUniqueIDs.append(item.sourceNodeID)
            }
        }

        return orderedUniqueIDs
    }

    private static func wordCount(in value: String) -> Int {
        value.split(whereSeparator: \.isWhitespace).count
    }
}

final class AVAudioEngineRecorder: NSObject, AudioCapturing, @unchecked Sendable {
    private let audioEngine: AVAudioEngine
    private let targetFormat: AVAudioFormat
    private let maxCapturedBytes: Int
    private let captureLock = NSLock()

    private var converter: AVAudioConverter?
    private var capturedPCMData: Data = Data()
    private var hasReachedCaptureLimit = false
    private var isCapturing = false

    init(
        audioEngine: AVAudioEngine = AVAudioEngine(),
        maxRecordingDuration: TimeInterval = 60
    ) {
        self.audioEngine = audioEngine
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
        let cappedDuration = max(1, Int(ceil(maxRecordingDuration)))
        self.maxCapturedBytes = 16_000 * MemoryLayout<Int16>.size * cappedDuration
        super.init()
    }

    func startCapture() async throws {
        do {
            try await MainActor.run {
                try startCaptureOnMainActor()
            }
        } catch let error as AudioServiceError {
            throw error
        } catch {
            throw AudioServiceError.captureFailed(error.localizedDescription)
        }
    }

    func stopCapture() async throws -> RecordedAudioClip {
        do {
            try await MainActor.run {
                try stopCaptureOnMainActor()
            }
        } catch let error as AudioServiceError {
            throw error
        } catch {
            throw AudioServiceError.captureFailed(error.localizedDescription)
        }

        let clipData = consumeCapturedPCMData()

        return RecordedAudioClip(
            data: clipData,
            sampleRate: 16_000,
            channels: 1,
            bitsPerSample: 16
        )
    }

    @MainActor
    private func startCaptureOnMainActor() throws {
        guard !isCapturing else {
            throw AudioServiceError.alreadyRecording
        }

        // Log microphone permission status before touching the audio engine.
        let micStatus: String
        switch AVAudioApplication.shared.recordPermission {
        case .granted:   micStatus = "granted"
        case .denied:    micStatus = "DENIED"
        case .undetermined: micStatus = "undetermined"
        @unknown default: micStatus = "unknown"
        }
        NSLog("[Audio] Microphone permission: %@", micStatus)
        guard AVAudioApplication.shared.recordPermission == .granted else {
            NSLog("[Audio] ❌ Microphone permission not granted — recording will be silent")
            // Don't throw here; let the user see the permission prompt via the UI.
            // We continue so that if permission is later granted the engine can start.
            return
        }

        // Configure the audio session for recording BEFORE touching AVAudioEngine.
        // The default category (.soloAmbient) is playback-only; without .playAndRecord
        // the inputNode produces silence with no error, which fails the hasSpeech check.
        let session = AVAudioSession.sharedInstance()
        do {
            // .voiceChat enables proper mic gain + echo cancellation for speech input.
            // .measurement was wrong — it disables hardware gain, causing near-zero amplitude.
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            NSLog("[Audio] Session category set to playAndRecord/voiceChat — input available: %@, gain: %.2f",
                  session.isInputAvailable ? "yes" : "no", session.inputGain)
        } catch {
            NSLog("[Audio] ❌ Failed to configure audio session: %@", error.localizedDescription)
            throw AudioServiceError.captureFailed("Audio session setup failed: \(error.localizedDescription)")
        }

        // NOTE: Do NOT call audioEngine.reset() here — it disconnects the inputNode
        // from hardware and causes near-zero amplitude (silence) on the tap.

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        NSLog("[Audio] Input node format — sample rate: %.0f Hz, channels: %d, formatID: %u",
              inputFormat.sampleRate, inputFormat.channelCount,
              inputFormat.streamDescription.pointee.mFormatID)

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioServiceError.invalidAudioFormat
        }

        self.converter = converter
        captureLock.lock()
        capturedPCMData.removeAll(keepingCapacity: true)
        hasReachedCaptureLimit = false
        captureLock.unlock()

        inputNode.removeTap(onBus: 0)
        var tapCallCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { [weak self] buffer, _ in
            tapCallCount += 1
            if tapCallCount <= 3 || tapCallCount % 20 == 0 {
                // Log first 3 callbacks and every 20th after to confirm tap is firing
                var peak: Int16 = 0
                if let ch = buffer.floatChannelData {
                    let frameCount = Int(buffer.frameLength)
                    for i in 0..<frameCount {
                        let sample = Int16(ch[0][i] * 32767)
                        if abs(sample) > abs(peak) { peak = sample }
                    }
                }
                NSLog("[Audio] TAP callback #%d — frames: %d, peak: %d",
                      tapCallCount, buffer.frameLength, peak)
            }
            self?.appendConvertedBuffer(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isCapturing = true
            NSLog("[Audio] ✅ Recording started — engine running: %@", audioEngine.isRunning ? "yes" : "no")
        } catch {
            inputNode.removeTap(onBus: 0)
            self.converter = nil
            NSLog("[Audio] ❌ Failed to start audio engine: %@", error.localizedDescription)
            throw AudioServiceError.captureFailed(error.localizedDescription)
        }
    }

    @MainActor
    private func stopCaptureOnMainActor() throws {
        guard isCapturing else {
            throw AudioServiceError.notRecording
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        converter = nil
        isCapturing = false
    }

    private func appendConvertedBuffer(_ inputBuffer: AVAudioPCMBuffer) {
        captureLock.lock()
        defer { captureLock.unlock() }

        guard !hasReachedCaptureLimit, let converter else {
            return
        }

        let rateRatio = targetFormat.sampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(max(1, Int(Double(inputBuffer.frameLength) * rateRatio) + 16))
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return
        }

        var hasSuppliedInput = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if hasSuppliedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            hasSuppliedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard conversionError == nil,
              conversionStatus != .error,
              outputBuffer.frameLength > 0,
              let channelData = outputBuffer.int16ChannelData else {
            return
        }

        let byteCount = Int(outputBuffer.frameLength) * MemoryLayout<Int16>.size
        let convertedData = Data(bytes: channelData.pointee, count: byteCount)

        if capturedPCMData.count + convertedData.count > maxCapturedBytes {
            let remainingBytes = max(0, maxCapturedBytes - capturedPCMData.count)
            if remainingBytes > 0 {
                capturedPCMData.append(convertedData.prefix(remainingBytes))
            }
            hasReachedCaptureLimit = true
            return
        }

        capturedPCMData.append(convertedData)
    }

    private func consumeCapturedPCMData() -> Data {
        captureLock.lock()
        defer { captureLock.unlock() }
        let clipData = capturedPCMData
        capturedPCMData.removeAll(keepingCapacity: true)
        return clipData
    }
}

actor AudioService {
    struct TranscriptResult: Equatable, Sendable {
        let sequence: Int
        let transcript: String
        let clipDurationSeconds: TimeInterval
    }

    private struct PendingClip: Sendable {
        let sequence: Int
        let clip: RecordedAudioClip
    }

    private let capturer: AudioCapturing
    private let transcriber: CactusTranscribing
    private let transcriptConsumer: TranscriptConsuming?
    private let maxRecordingDuration: TimeInterval
    private let silenceAmplitudeThreshold: Int16
    private let minimumActiveSamples: Int

    private var isRecording = false
    private var nextSequence = 0
    private var pendingClips: [PendingClip] = []
    private var processingTask: Task<Void, Never>?

    private(set) var transcriptHistory: [TranscriptResult] = []

    init(
        capturer: AudioCapturing = AVAudioEngineRecorder(),
        transcriber: CactusTranscribing = CactusTranscriber(),
        transcriptConsumer: TranscriptConsuming? = nil,
        maxRecordingDuration: TimeInterval = 60,
        silenceAmplitudeThreshold: Int16 = 500,
        minimumActiveSamples: Int = 160
    ) {
        self.capturer = capturer
        self.transcriber = transcriber
        self.transcriptConsumer = transcriptConsumer
        self.maxRecordingDuration = maxRecordingDuration
        self.silenceAmplitudeThreshold = silenceAmplitudeThreshold
        self.minimumActiveSamples = minimumActiveSamples
    }

    func pttPressed() async throws {
        guard !isRecording else {
            throw AudioServiceError.alreadyRecording
        }

        do {
            try await capturer.startCapture()
            isRecording = true
        } catch let error as AudioServiceError {
            throw error
        } catch {
            throw AudioServiceError.captureFailed(error.localizedDescription)
        }
    }

    @discardableResult
    func pttReleased() async throws -> Int? {
        guard isRecording else {
            throw AudioServiceError.notRecording
        }

        let capturedClip: RecordedAudioClip
        do {
            capturedClip = try await capturer.stopCapture()
            isRecording = false
        } catch {
            isRecording = false
            if let audioError = error as? AudioServiceError {
                throw audioError
            }
            throw AudioServiceError.captureFailed(error.localizedDescription)
        }

        let clippedAudio = capturedClip.capped(to: maxRecordingDuration)
        guard clippedAudio.isPCM16kMono16Bit else {
            throw AudioServiceError.invalidAudioFormat
        }

        guard clippedAudio.hasSpeech(
            amplitudeThreshold: silenceAmplitudeThreshold,
            minimumActiveSamples: minimumActiveSamples
        ) else {
            return nil
        }

        let sequence = nextSequence
        nextSequence += 1
        pendingClips.append(PendingClip(sequence: sequence, clip: clippedAudio))
        startProcessingIfNeeded()
        return sequence
    }

    func waitForIdle() async {
        while processingTask != nil || !pendingClips.isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func startProcessingIfNeeded() {
        guard processingTask == nil else {
            return
        }

        processingTask = Task {
            await processPendingClips()
        }
    }

    private func processPendingClips() async {
        while !pendingClips.isEmpty {
            let item = pendingClips.removeFirst()

            do {
                let transcript = try await transcriber.transcribePCM16kMono(item.clip.data)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !transcript.isEmpty else {
                    continue
                }

                let result = TranscriptResult(
                    sequence: item.sequence,
                    transcript: transcript,
                    clipDurationSeconds: item.clip.durationSeconds
                )
                transcriptHistory.append(result)
                if let transcriptConsumer {
                    await transcriptConsumer.receiveTranscript(result)
                }
            } catch {
                continue
            }
        }

        processingTask = nil
        if !pendingClips.isEmpty {
            startProcessingIfNeeded()
        }
    }
}

enum PeerConnectionState: String, Equatable, Sendable {
    case connected
    case disconnected
}

struct NetworkAdvertisement: Equatable, Sendable {
    let networkID: UUID
    let networkName: String
    let openSlotCount: Int
    let requiresPIN: Bool

    init(networkID: UUID, networkName: String, openSlotCount: Int, requiresPIN: Bool) {
        self.networkID = networkID
        self.networkName = networkName
        self.openSlotCount = max(0, openSlotCount)
        self.requiresPIN = requiresPIN
    }

    init(from config: NetworkConfig) {
        self.init(
            networkID: config.networkID,
            networkName: config.networkName,
            openSlotCount: config.openSlotCount,
            requiresPIN: config.requiresPIN
        )
    }
}

struct DiscoveredNetwork: Identifiable, Equatable, Sendable {
    var id: UUID { peerID }
    let peerID: UUID
    let networkID: UUID
    let networkName: String
    let openSlotCount: Int
    let requiresPIN: Bool
}

private enum NetworkAdvertisementCodec {
    // CBPeripheralManager.startAdvertising only supports CBAdvertisementDataLocalNameKey
    // and CBAdvertisementDataServiceUUIDsKey. ServiceData is a read-only central-side key
    // and will crash with NSInvalidArgumentException if passed to startAdvertising.
    //
    // Metadata encoding: append "|XX" to the local name where XX is one hex byte:
    //   bits [7:4] = openSlotCount clamped to 0-15
    //   bit  [0]   = requiresPIN flag
    // The real networkID is fetched via GATT treeConfig read during join.

    private static let metaSuffixLength = 3  // "|XX"
    private static let maxNetworkNameLength = 17  // 20 - 3 = 17 chars for the name itself

    static func advertisingData(for summary: NetworkAdvertisement) -> [String: Any] {
        let clampedSlots = min(summary.openSlotCount, 15)
        let metaByte = UInt8((clampedSlots << 1) | (summary.requiresPIN ? 1 : 0))
        let metaSuffix = String(format: "|%02X", metaByte)

        let trimmedName = String(summary.networkName.prefix(maxNetworkNameLength))
        let advertisedName = trimmedName + metaSuffix

        return [
            CBAdvertisementDataServiceUUIDsKey: [BluetoothMeshUUIDs.service],
            CBAdvertisementDataLocalNameKey: advertisedName
        ]
    }

    // peerID is used as a proxy networkID; the real networkID is confirmed during GATT join.
    static func decode(advertisementData: [String: Any], peerID: UUID) -> NetworkAdvertisement? {
        guard let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
              serviceUUIDs.contains(BluetoothMeshUUIDs.service) else {
            return nil
        }

        let rawName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""

        var networkName = rawName
        var openSlotCount = 0
        var requiresPIN = false

        if rawName.count >= metaSuffixLength {
            let suffix = String(rawName.suffix(metaSuffixLength))
            if suffix.first == "|", let metaByte = UInt8(suffix.dropFirst(), radix: 16) {
                networkName = String(rawName.dropLast(metaSuffixLength))
                requiresPIN = (metaByte & 0x01) != 0
                openSlotCount = Int((metaByte >> 1) & 0x0F)
            }
        }

        networkName = networkName.trimmingCharacters(in: .whitespacesAndNewlines)
        if networkName.isEmpty { networkName = "TacNet Network" }

        return NetworkAdvertisement(
            networkID: peerID,
            networkName: networkName,
            openSlotCount: openSlotCount,
            requiresPIN: requiresPIN
        )
    }
}

enum BluetoothMeshTransportError: Error {
    case unsupportedTreeConfigRead
    case unknownPeer
    case treeConfigUnavailable
}

enum BluetoothMeshTransportEvent: Sendable {
    case discoveredPeer(UUID)
    case discoveredNetwork(UUID, NetworkAdvertisement)
    case connectionStateChanged(UUID, PeerConnectionState)
    case receivedData(Data, from: UUID)
}

protocol BluetoothMeshTransporting: AnyObject {
    var eventHandler: ((BluetoothMeshTransportEvent) -> Void)? { get set }

    func start()
    func stop()
    func send(_ data: Data, messageType: Message.MessageType, to peerIDs: Set<UUID>)
    func configureAdvertisement(_ summary: NetworkAdvertisement?)
    func updateTreeConfigPayload(_ data: Data)
    func requestTreeConfig(from peerID: UUID, completion: @escaping (Result<Data, Error>) -> Void)
}

extension BluetoothMeshTransporting {
    func configureAdvertisement(_: NetworkAdvertisement?) {}

    func updateTreeConfigPayload(_: Data) {}

    func requestTreeConfig(from _: UUID, completion: @escaping (Result<Data, Error>) -> Void) {
        completion(.failure(BluetoothMeshTransportError.unsupportedTreeConfigRead))
    }
}

private enum BluetoothMeshCharacteristicKind: CaseIterable {
    case broadcast
    case compaction
    case treeConfig

    var uuid: CBUUID {
        switch self {
        case .broadcast:
            return BluetoothMeshUUIDs.broadcastCharacteristic
        case .compaction:
            return BluetoothMeshUUIDs.compactionCharacteristic
        case .treeConfig:
            return BluetoothMeshUUIDs.treeConfigCharacteristic
        }
    }
}

final class BluetoothMeshService {
    typealias MessageHandler = (Message) -> Void
    typealias PeerStateHandler = (UUID, PeerConnectionState) -> Void
    typealias PeerDiscoveryHandler = (UUID) -> Void
    typealias NetworkDiscoveryHandler = (UUID, NetworkAdvertisement) -> Void

    var onMessageReceived: MessageHandler?
    var onPeerConnectionStateChanged: PeerStateHandler?
    var onPeerDiscovered: PeerDiscoveryHandler?
    var onNetworkDiscovered: NetworkDiscoveryHandler?

    private let transport: BluetoothMeshTransporting
    private let deduplicator: MessageDeduplicator
    private let encryptionService: NetworkEncryptionService
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var peerStates: [UUID: PeerConnectionState] = [:]

    private struct QueuedRelay {
        let message: Message
        let excludedPeerID: UUID?
    }
    private var relayQueue: [QueuedRelay] = []

    init(
        transport: BluetoothMeshTransporting = CoreBluetoothMeshTransport(),
        deduplicator: MessageDeduplicator = MessageDeduplicator(),
        encryptionService: NetworkEncryptionService = NetworkEncryptionService()
    ) {
        self.transport = transport
        self.deduplicator = deduplicator
        self.encryptionService = encryptionService
        self.transport.eventHandler = { [weak self] event in
            self?.handleTransportEvent(event)
        }
    }

    func start() {
        transport.start()
    }

    func stop() {
        transport.stop()
    }

    func publishNetwork(_ networkConfig: NetworkConfig) {
        transport.configureAdvertisement(NetworkAdvertisement(from: networkConfig))
        if let payload = try? encoder.encode(networkConfig) {
            transport.updateTreeConfigPayload(payload)
        }
        start()
    }

    func updatePublishedNetwork(_ networkConfig: NetworkConfig) {
        publishNetwork(networkConfig)
    }

    func clearPublishedNetwork() {
        transport.configureAdvertisement(nil)
        transport.updateTreeConfigPayload(Data())
        clearSessionKey()
    }

    func fetchNetworkConfig(from peerID: UUID, completion: @escaping (Result<NetworkConfig, Error>) -> Void) {
        transport.requestTreeConfig(from: peerID) { result in
            switch result {
            case .success(let data):
                do {
                    let decoded = try JSONDecoder().decode(NetworkConfig.self, from: data)
                    completion(.success(decoded))
                } catch {
                    completion(.failure(error))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    func fetchNetworkConfig(from peerID: UUID) async throws -> NetworkConfig {
        try await withCheckedThrowingContinuation { continuation in
            fetchNetworkConfig(from: peerID) { result in
                continuation.resume(with: result)
            }
        }
    }

    func publish(_ message: Message) {
        var outboundMessage = message
        if encryptionService.hasActiveSessionKey {
            outboundMessage.payload.encrypted = true
        }

        guard outboundMessage.ttl > 0 else {
            return
        }

        guard !deduplicator.isDuplicate(messageId: outboundMessage.id) else {
            return
        }

        flood(outboundMessage, excluding: nil)
    }

    func hasActiveSessionKey(for networkID: UUID) -> Bool {
        encryptionService.hasSessionKey(for: networkID)
    }

    func prepareSessionKeyForPublishing(networkID: UUID, keyMaterial: String) throws -> String {
        try encryptionService.makeWrappedSessionKey(networkID: networkID, keyMaterial: keyMaterial)
    }

    func activateSessionKey(
        networkID: UUID,
        wrappedSessionKey: String,
        keyMaterial: String
    ) throws {
        try encryptionService.activateSessionKey(
            networkID: networkID,
            wrappedSessionKey: wrappedSessionKey,
            keyMaterial: keyMaterial
        )
    }

    func activateDeterministicSessionKey(networkID: UUID, keyMaterial: String) {
        encryptionService.activateDeterministicSessionKey(networkID: networkID, keyMaterial: keyMaterial)
    }

    func clearSessionKey() {
        encryptionService.clearSessionKey()
    }

    func connectionState(for peerID: UUID) -> PeerConnectionState {
        peerStates[peerID] ?? .disconnected
    }

    var connectedPeerIDs: Set<UUID> {
        Set(
            peerStates.compactMap { peerID, state in
                state == .connected ? peerID : nil
            }
        )
    }

    var pendingRelayCount: Int {
        relayQueue.count
    }

    /// UI-test-only hook: seeds `count` deterministic fake peer IDs as `.connected`
    /// in `peerStates` and invokes `onPeerConnectionStateChanged` for each so
    /// `MainViewModel` observers (via `refreshConnectionState` / the per-peer
    /// callback) pick up `isConnected == true` without requiring real BLE.
    ///
    /// Activated by `AppNetworkCoordinator` when the app is launched with
    /// `--ui-test-mesh-peers=<N>`. Production code paths never call this.
    func seedUITestConnectedPeers(count: Int) {
        guard count > 0 else { return }
        for index in 0..<count {
            let seed = String(
                format: "ui-test-peer-%08x-%04x-%04x-%04x-%012x",
                0xCAFEBABE,
                0xFADE,
                0xC0DE,
                0xBEEF,
                index
            )
            let peerID = UUID(uuidString: seed) ?? UUID()
            peerStates[peerID] = .connected
            onPeerConnectionStateChanged?(peerID, .connected)
        }
        NSLog("[BLE] UI-test mode — seeded %d fake connected peer(s)", count)
    }

    private func handleTransportEvent(_ event: BluetoothMeshTransportEvent) {
        switch event {
        case .discoveredPeer(let peerID):
            onPeerDiscovered?(peerID)

        case .discoveredNetwork(let peerID, let summary):
            onNetworkDiscovered?(peerID, summary)

        case .connectionStateChanged(let peerID, let state):
            peerStates[peerID] = state
            onPeerConnectionStateChanged?(peerID, state)

            if state == .connected {
                flushRelayQueue(to: peerID)
            }

        case .receivedData(let data, let sourcePeerID):
            handleIncomingData(data, from: sourcePeerID)
        }
    }

    private func handleIncomingData(_ data: Data, from sourcePeerID: UUID) {
        let decryptedData: Data
        do {
            decryptedData = try encryptionService.decryptTransportPayload(data)
        } catch {
            return
        }

        guard var inboundMessage = try? decoder.decode(Message.self, from: decryptedData) else {
            return
        }

        guard inboundMessage.ttl > 0 else {
            return
        }

        guard !deduplicator.isDuplicate(messageId: inboundMessage.id) else {
            return
        }

        inboundMessage.ttl -= 1
        onMessageReceived?(inboundMessage)

        guard inboundMessage.ttl > 0 else {
            return
        }

        flood(inboundMessage, excluding: sourcePeerID)
    }

    private func flood(_ message: Message, excluding excludedPeerID: UUID?) {
        var targetPeerIDs = connectedPeerIDs
        if let excludedPeerID {
            targetPeerIDs.remove(excludedPeerID)
        }

        guard !targetPeerIDs.isEmpty else {
            relayQueue.append(QueuedRelay(message: message, excludedPeerID: excludedPeerID))
            return
        }

        send(message, to: targetPeerIDs)
    }

    private func flushRelayQueue(to peerID: UUID) {
        guard connectionState(for: peerID) == .connected else {
            return
        }

        var remaining: [QueuedRelay] = []

        for item in relayQueue {
            if item.excludedPeerID == peerID {
                remaining.append(item)
                continue
            }

            send(item.message, to: [peerID])
        }

        relayQueue = remaining
    }

    private func send(_ message: Message, to peerIDs: Set<UUID>) {
        guard let encodedMessage = try? encoder.encode(message) else {
            return
        }

        let outboundPayload: Data
        do {
            outboundPayload = try encryptionService.encryptTransportPayload(encodedMessage)
        } catch {
            return
        }

        transport.send(outboundPayload, messageType: message.type, to: peerIDs)
    }
}

final class CoreBluetoothMeshTransport: NSObject, BluetoothMeshTransporting {
    var eventHandler: ((BluetoothMeshTransportEvent) -> Void)?

    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?

    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private var connectingPeripheralIDs: Set<UUID> = []
    private var discoveredCharacteristicsByPeer: [UUID: [BluetoothMeshCharacteristicKind: CBCharacteristic]] = [:]
    private var subscribedCentrals: [UUID: CBCentral] = [:]

    private var hasPublishedService = false
    private var treeConfigPayload: Data = Data()
    private var advertisedNetworkSummary: NetworkAdvertisement?
    private var pendingTreeConfigReadCompletions: [UUID: [(Result<Data, Error>) -> Void]] = [:]

    private lazy var broadcastCharacteristic: CBMutableCharacteristic = {
        CBMutableCharacteristic(
            type: BluetoothMeshUUIDs.broadcastCharacteristic,
            properties: [.read, .write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
    }()

    private lazy var compactionCharacteristic: CBMutableCharacteristic = {
        CBMutableCharacteristic(
            type: BluetoothMeshUUIDs.compactionCharacteristic,
            properties: [.read, .write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )
    }()

    private lazy var treeConfigCharacteristic: CBMutableCharacteristic = {
        CBMutableCharacteristic(
            type: BluetoothMeshUUIDs.treeConfigCharacteristic,
            properties: [.read],
            value: nil,
            permissions: [.readable]
        )
    }()

    func start() {
        NSLog("[BLE] start() — central: %@, peripheral: %@",
              centralManager == nil ? "nil" : centralManager!.state.logDescription,
              peripheralManager == nil ? "nil" : peripheralManager!.state.logDescription)

        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil)
        }
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        }

        if centralManager?.state == .poweredOn {
            startScanning()
        }
        if peripheralManager?.state == .poweredOn {
            publishServiceIfNeeded()
            startAdvertising()
        }
    }

    func stop() {
        NSLog("[BLE] stop()")
        centralManager?.stopScan()
        for peripheral in connectedPeripherals.values {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        peripheralManager?.stopAdvertising()

        for peerID in Array(pendingTreeConfigReadCompletions.keys) {
            completeTreeConfigReads(
                for: peerID,
                result: .failure(BluetoothMeshTransportError.treeConfigUnavailable)
            )
        }

        discoveredPeripherals.removeAll()
        connectingPeripheralIDs.removeAll()
        connectedPeripherals.removeAll()
        discoveredCharacteristicsByPeer.removeAll()
        subscribedCentrals.removeAll()
    }

    func send(_ data: Data, messageType: Message.MessageType, to peerIDs: Set<UUID>) {
        let characteristicKind = characteristicKind(for: messageType)

        for peerID in peerIDs {
            if let peripheral = connectedPeripherals[peerID],
               let characteristic = discoveredCharacteristicsByPeer[peerID]?[characteristicKind] {
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                continue
            }

            if let central = subscribedCentrals[peerID],
               let peripheralManager {
                let localCharacteristic = localCharacteristic(for: characteristicKind)
                _ = peripheralManager.updateValue(data, for: localCharacteristic, onSubscribedCentrals: [central])
            }
        }
    }

    func configureAdvertisement(_ summary: NetworkAdvertisement?) {
        advertisedNetworkSummary = summary
        guard peripheralManager?.state == .poweredOn else {
            return
        }
        startAdvertising()
    }

    func updateTreeConfigPayload(_ data: Data) {
        treeConfigPayload = data
    }

    func requestTreeConfig(from peerID: UUID, completion: @escaping (Result<Data, Error>) -> Void) {
        NSLog("[Join] requestTreeConfig — peerID: %@, connected: %@, characteristics known: %@",
              peerID.uuidString,
              connectedPeripherals[peerID] != nil ? "yes" : "no",
              discoveredCharacteristicsByPeer[peerID] != nil ? "yes" : "no")

        pendingTreeConfigReadCompletions[peerID, default: []].append(completion)

        // Timeout: if the GATT read hasn't completed in 10s, fail the join.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self,
                  self.pendingTreeConfigReadCompletions[peerID] != nil else { return }
            NSLog("[Join] ⏱ requestTreeConfig timed out for peer %@", peerID.uuidString)
            self.completeTreeConfigReads(
                for: peerID,
                result: .failure(BluetoothMeshTransportError.treeConfigUnavailable)
            )
        }

        if centralManager == nil || peripheralManager == nil {
            NSLog("[Join] BLE stack not started — calling start()")
            start()
        }

        guard let peripheral = connectedPeripherals[peerID] ?? discoveredPeripherals[peerID] else {
            NSLog("[Join] ❌ Peer %@ not in discovered or connected set — failing immediately", peerID.uuidString)
            completeTreeConfigReads(for: peerID, result: .failure(BluetoothMeshTransportError.unknownPeer))
            return
        }

        peripheral.delegate = self

        if let characteristic = discoveredCharacteristicsByPeer[peerID]?[.treeConfig] {
            NSLog("[Join] Characteristics already known — reading treeConfig now")
            peripheral.readValue(for: characteristic)
            return
        }

        // Not yet connected or characteristics not yet discovered — queue the read.
        // didConnect → discoverServices → didDiscoverCharacteristics → attemptTreeConfigRead
        // will resume the completion when ready.
        if connectedPeripherals[peerID] != nil {
            NSLog("[Join] Connected but no characteristics yet — triggering service discovery")
            peripheral.discoverServices([BluetoothMeshUUIDs.service])
        } else if let centralManager, centralManager.state == .poweredOn,
                  !connectingPeripheralIDs.contains(peerID) {
            NSLog("[Join] Not connected — initiating connection to peer %@", peerID.uuidString)
            connectingPeripheralIDs.insert(peerID)
            centralManager.connect(peripheral, options: nil)
        } else {
            NSLog("[Join] Waiting for in-progress connection to peer %@ (state: %@)",
                  peerID.uuidString, centralManager?.state.logDescription ?? "nil")
        }
    }

    private func startScanning() {
        NSLog("[BLE] Scanning for TacNet peripherals…")
        centralManager?.scanForPeripherals(
            withServices: [BluetoothMeshUUIDs.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    private func startAdvertising() {
        guard let peripheralManager else {
            return
        }

        peripheralManager.stopAdvertising()
        if let advertisedNetworkSummary {
            NSLog("[BLE] Advertising network '%@' (slots: %d, PIN: %@)",
                  advertisedNetworkSummary.networkName, advertisedNetworkSummary.openSlotCount,
                  advertisedNetworkSummary.requiresPIN ? "yes" : "no")
            peripheralManager.startAdvertising(NetworkAdvertisementCodec.advertisingData(for: advertisedNetworkSummary))
        } else {
            NSLog("[BLE] Advertising (no network — service UUID only)")
            peripheralManager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [BluetoothMeshUUIDs.service]
            ])
        }
    }

    private func publishServiceIfNeeded() {
        guard !hasPublishedService else {
            return
        }

        let service = CBMutableService(type: BluetoothMeshUUIDs.service, primary: true)
        service.characteristics = [
            broadcastCharacteristic,
            compactionCharacteristic,
            treeConfigCharacteristic
        ]

        peripheralManager?.add(service)
        hasPublishedService = true
    }

    private func characteristicKind(for messageType: Message.MessageType) -> BluetoothMeshCharacteristicKind {
        switch messageType {
        case .compaction:
            return .compaction
        default:
            return .broadcast
        }
    }

    private func localCharacteristic(for kind: BluetoothMeshCharacteristicKind) -> CBMutableCharacteristic {
        switch kind {
        case .broadcast:
            return broadcastCharacteristic
        case .compaction:
            return compactionCharacteristic
        case .treeConfig:
            return treeConfigCharacteristic
        }
    }

    private func attemptTreeConfigRead(for peerID: UUID) {
        let hasPending = pendingTreeConfigReadCompletions[peerID] != nil
        let isConnected = connectedPeripherals[peerID] != nil
        let hasChar = discoveredCharacteristicsByPeer[peerID]?[.treeConfig] != nil

        NSLog("[Join] attemptTreeConfigRead for %@ — pending: %@, connected: %@, hasChar: %@",
              peerID.uuidString,
              hasPending ? "yes" : "no",
              isConnected ? "yes" : "no",
              hasChar ? "yes" : "no")

        guard hasPending,
              let peripheral = connectedPeripherals[peerID],
              let treeConfigCharacteristic = discoveredCharacteristicsByPeer[peerID]?[.treeConfig] else {
            return
        }

        NSLog("[Join] Issuing GATT read for treeConfig on peer %@", peerID.uuidString)
        peripheral.readValue(for: treeConfigCharacteristic)
    }

    private func completeTreeConfigReads(for peerID: UUID, result: Result<Data, Error>) {
        guard let completions = pendingTreeConfigReadCompletions.removeValue(forKey: peerID) else {
            return
        }

        completions.forEach { completion in
            completion(result)
        }
    }
}

extension CoreBluetoothMeshTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        NSLog("[BLE] Central state → %@", central.state.logDescription)
        guard central.state == .poweredOn else {
            return
        }
        startScanning()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name ?? "unnamed"
        discoveredPeripherals[peripheral.identifier] = peripheral
        eventHandler?(.discoveredPeer(peripheral.identifier))
        if let advertisement = NetworkAdvertisementCodec.decode(advertisementData: advertisementData, peerID: peripheral.identifier) {
            NSLog("[BLE] Discovered network '%@' from peer %@ (slots: %d, PIN: %@)",
                  advertisement.networkName, peripheral.identifier.uuidString,
                  advertisement.openSlotCount, advertisement.requiresPIN ? "yes" : "no")
            eventHandler?(.discoveredNetwork(peripheral.identifier, advertisement))
        } else {
            NSLog("[BLE] Discovered peer %@ ('%@') — no TacNet advertisement", peripheral.identifier.uuidString, name)
        }

        if connectedPeripherals[peripheral.identifier] == nil,
           !connectingPeripheralIDs.contains(peripheral.identifier) {
            NSLog("[BLE] Connecting to peer %@…", peripheral.identifier.uuidString)
            connectingPeripheralIDs.insert(peripheral.identifier)
            central.connect(peripheral, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        NSLog("[BLE] ✅ Connected to peer %@", peripheral.identifier.uuidString)
        connectingPeripheralIDs.remove(peripheral.identifier)
        connectedPeripherals[peripheral.identifier] = peripheral
        eventHandler?(.connectionStateChanged(peripheral.identifier, .connected))

        peripheral.delegate = self
        peripheral.discoverServices([BluetoothMeshUUIDs.service])
        attemptTreeConfigRead(for: peripheral.identifier)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        NSLog("[BLE] ❌ Failed to connect to peer %@: %@",
              peripheral.identifier.uuidString, error?.localizedDescription ?? "unknown")
        connectingPeripheralIDs.remove(peripheral.identifier)
        eventHandler?(.connectionStateChanged(peripheral.identifier, .disconnected))
        completeTreeConfigReads(
            for: peripheral.identifier,
            result: .failure(error ?? BluetoothMeshTransportError.treeConfigUnavailable)
        )
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        NSLog("[BLE] Peer %@ disconnected%@", peripheral.identifier.uuidString,
              error != nil ? " (error: \(error!.localizedDescription))" : "")
        connectingPeripheralIDs.remove(peripheral.identifier)
        connectedPeripherals.removeValue(forKey: peripheral.identifier)
        discoveredCharacteristicsByPeer.removeValue(forKey: peripheral.identifier)
        eventHandler?(.connectionStateChanged(peripheral.identifier, .disconnected))
        completeTreeConfigReads(
            for: peripheral.identifier,
            result: .failure(error ?? BluetoothMeshTransportError.treeConfigUnavailable)
        )
    }
}

extension CoreBluetoothMeshTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            NSLog("[Join] ❌ didDiscoverServices error for peer %@: %@",
                  peripheral.identifier.uuidString, error.localizedDescription)
            completeTreeConfigReads(for: peripheral.identifier, result: .failure(error))
            return
        }

        let serviceCount = peripheral.services?.count ?? 0
        let hasTacNetService = peripheral.services?.contains(where: { $0.uuid == BluetoothMeshUUIDs.service }) ?? false
        NSLog("[Join] didDiscoverServices for peer %@ — %d service(s), TacNet service found: %@",
              peripheral.identifier.uuidString, serviceCount, hasTacNetService ? "yes" : "no")

        peripheral.services?
            .filter { $0.uuid == BluetoothMeshUUIDs.service }
            .forEach { service in
                peripheral.discoverCharacteristics(BluetoothMeshCharacteristicKind.allCases.map(\.uuid), for: service)
            }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error {
            NSLog("[Join] ❌ didDiscoverCharacteristics error for peer %@: %@",
                  peripheral.identifier.uuidString, error.localizedDescription)
            completeTreeConfigReads(for: peripheral.identifier, result: .failure(error))
            return
        }

        var map: [BluetoothMeshCharacteristicKind: CBCharacteristic] = [:]

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case BluetoothMeshUUIDs.broadcastCharacteristic:
                map[.broadcast] = characteristic
            case BluetoothMeshUUIDs.compactionCharacteristic:
                map[.compaction] = characteristic
            case BluetoothMeshUUIDs.treeConfigCharacteristic:
                map[.treeConfig] = characteristic
            default:
                break
            }

            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }

        NSLog("[Join] didDiscoverCharacteristics for peer %@ — broadcast: %@, compaction: %@, treeConfig: %@",
              peripheral.identifier.uuidString,
              map[.broadcast] != nil ? "✅" : "❌",
              map[.compaction] != nil ? "✅" : "❌",
              map[.treeConfig] != nil ? "✅" : "❌")

        discoveredCharacteristicsByPeer[peripheral.identifier] = map
        attemptTreeConfigRead(for: peripheral.identifier)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == BluetoothMeshUUIDs.treeConfigCharacteristic,
           pendingTreeConfigReadCompletions[peripheral.identifier] != nil {
            if let error {
                NSLog("[Join] ❌ treeConfig read error for peer %@: %@",
                      peripheral.identifier.uuidString, error.localizedDescription)
                completeTreeConfigReads(for: peripheral.identifier, result: .failure(error))
            } else if let value = characteristic.value {
                NSLog("[Join] ✅ treeConfig read success for peer %@ — %d bytes",
                      peripheral.identifier.uuidString, value.count)
                completeTreeConfigReads(for: peripheral.identifier, result: .success(value))
            } else {
                NSLog("[Join] ❌ treeConfig read returned nil value for peer %@",
                      peripheral.identifier.uuidString)
                completeTreeConfigReads(
                    for: peripheral.identifier,
                    result: .failure(BluetoothMeshTransportError.treeConfigUnavailable)
                )
            }
            return
        }

        guard error == nil, let value = characteristic.value else {
            return
        }

        eventHandler?(.receivedData(value, from: peripheral.identifier))
    }
}

extension CoreBluetoothMeshTransport: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        NSLog("[BLE] Peripheral state → %@", peripheral.state.logDescription)
        guard peripheral.state == .poweredOn else {
            return
        }

        publishServiceIfNeeded()
        startAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            NSLog("[BLE] ❌ Failed to add GATT service: %@", error.localizedDescription)
            return
        }
        NSLog("[BLE] ✅ GATT service published")
        startAdvertising()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        NSLog("[Join] Received GATT read request from central %@ — characteristic: %@, offset: %d, payload size: %d",
              request.central.identifier.uuidString,
              request.characteristic.uuid.uuidString,
              request.offset,
              treeConfigPayload.count)

        guard request.characteristic.uuid == BluetoothMeshUUIDs.treeConfigCharacteristic else {
            NSLog("[Join] ❌ Read on unsupported characteristic — rejecting")
            peripheral.respond(to: request, withResult: .requestNotSupported)
            return
        }

        guard request.offset <= treeConfigPayload.count else {
            NSLog("[Join] ❌ Invalid offset %d (payload is %d bytes)", request.offset, treeConfigPayload.count)
            peripheral.respond(to: request, withResult: .invalidOffset)
            return
        }

        if treeConfigPayload.isEmpty {
            NSLog("[Join] ⚠️ treeConfigPayload is empty — joiner will get no data")
        } else {
            NSLog("[Join] ✅ Serving %d bytes of treeConfig (offset %d)",
                  treeConfigPayload.count - request.offset, request.offset)
        }

        request.value = treeConfigPayload.subdata(in: request.offset..<treeConfigPayload.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let value = request.value else {
                peripheral.respond(to: request, withResult: .invalidAttributeValueLength)
                continue
            }

            if request.characteristic.uuid == BluetoothMeshUUIDs.treeConfigCharacteristic {
                peripheral.respond(to: request, withResult: .requestNotSupported)
                continue
            }

            eventHandler?(.receivedData(value, from: request.central.identifier))
            peripheral.respond(to: request, withResult: .success)
        }
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        NSLog("[BLE] ✅ Central %@ subscribed to characteristic %@",
              central.identifier.uuidString, characteristic.uuid.uuidString)
        subscribedCentrals[central.identifier] = central
        eventHandler?(.connectionStateChanged(central.identifier, .connected))
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        NSLog("[BLE] Central %@ unsubscribed", central.identifier.uuidString)
        subscribedCentrals.removeValue(forKey: central.identifier)
        eventHandler?(.connectionStateChanged(central.identifier, .disconnected))
    }
}

enum TreeSyncConvergenceResult: Equatable {
    case adoptedInitial(version: Int)
    case replacedWithHigherVersion(previousVersion: Int, appliedVersion: Int)
    case ignoredStale(localVersion: Int, incomingVersion: Int)
    case ignoredDifferentNetwork(expectedNetworkID: UUID, incomingNetworkID: UUID)
}

enum TreeSyncJoinError: Error, Equatable {
    case treeConfigUnavailable
    case networkMismatch
    case pinRequired
    case invalidPIN
}

@MainActor
final class TreeSyncService: ObservableObject {
    @Published private(set) var localConfig: NetworkConfig?

    private let meshService: BluetoothMeshService
    private let configStore: NetworkConfigStore?
    private let disconnectTimeout: TimeInterval
    private var disconnectReparentTasks: [UUID: Task<Void, Never>] = [:]
    private let defaultTTL = 8

    init(
        meshService: BluetoothMeshService = BluetoothMeshService(),
        configStore: NetworkConfigStore? = nil,
        disconnectTimeout: TimeInterval = 60
    ) {
        self.meshService = meshService
        self.configStore = configStore
        self.disconnectTimeout = max(0, disconnectTimeout)
        self.localConfig = configStore?.load()
    }

    deinit {
        disconnectReparentTasks.values.forEach { $0.cancel() }
    }

    func setLocalConfig(_ config: NetworkConfig?) {
        localConfig = config
        persistLocalConfig(config)

        if config == nil {
            disconnectReparentTasks.values.forEach { $0.cancel() }
            disconnectReparentTasks.removeAll()
            meshService.clearSessionKey()
        }
    }

    func handlePeerStateChange(peerID: UUID, state: PeerConnectionState) {
        switch state {
        case .connected:
            cancelDisconnectTask(for: peerID)
        case .disconnected:
            scheduleDisconnectAutoReparent(for: peerID)
        }
    }

    func secureConfigForPublishing(_ config: NetworkConfig) -> NetworkConfig {
        var securedConfig = config
        let keyMaterial = NetworkEncryptionService.keyMaterial(
            pinHash: securedConfig.pinHash,
            networkID: securedConfig.networkID
        )

        if let existingConfig = localConfig,
           existingConfig.networkID == securedConfig.networkID,
           existingConfig.pinHash == securedConfig.pinHash,
           let existingWrappedSessionKey = existingConfig.encryptedSessionKey {
            securedConfig.encryptedSessionKey = existingWrappedSessionKey

            if !meshService.hasActiveSessionKey(for: securedConfig.networkID) {
                let didActivate = (try? meshService.activateSessionKey(
                    networkID: securedConfig.networkID,
                    wrappedSessionKey: existingWrappedSessionKey,
                    keyMaterial: keyMaterial
                )) != nil

                if !didActivate,
                   let regeneratedWrappedKey = try? meshService.prepareSessionKeyForPublishing(
                       networkID: securedConfig.networkID,
                       keyMaterial: keyMaterial
                   ) {
                    securedConfig.encryptedSessionKey = regeneratedWrappedKey
                } else if !didActivate {
                    meshService.activateDeterministicSessionKey(
                        networkID: securedConfig.networkID,
                        keyMaterial: keyMaterial
                    )
                    securedConfig.encryptedSessionKey = nil
                }
            }
            return securedConfig
        }

        if let suppliedWrappedSessionKey = securedConfig.encryptedSessionKey {
            let didActivate = (try? meshService.activateSessionKey(
                networkID: securedConfig.networkID,
                wrappedSessionKey: suppliedWrappedSessionKey,
                keyMaterial: keyMaterial
            )) != nil
            if didActivate {
                return securedConfig
            }
        }

        if let wrappedSessionKey = try? meshService.prepareSessionKeyForPublishing(
            networkID: securedConfig.networkID,
            keyMaterial: keyMaterial
        ) {
            securedConfig.encryptedSessionKey = wrappedSessionKey
        } else {
            meshService.activateDeterministicSessionKey(
                networkID: securedConfig.networkID,
                keyMaterial: keyMaterial
            )
            securedConfig.encryptedSessionKey = nil
        }

        return securedConfig
    }

    @discardableResult
    func converge(with incoming: NetworkConfig) -> TreeSyncConvergenceResult {
        guard let localConfig else {
            self.localConfig = incoming
            persistLocalConfig(incoming)
            return .adoptedInitial(version: incoming.version)
        }

        guard localConfig.networkID == incoming.networkID else {
            return .ignoredDifferentNetwork(
                expectedNetworkID: localConfig.networkID,
                incomingNetworkID: incoming.networkID
            )
        }

        guard incoming.version > localConfig.version else {
            return .ignoredStale(localVersion: localConfig.version, incomingVersion: incoming.version)
        }

        var mergedIncoming = incoming
        mergedIncoming.tree = Self.treeByPreservingClaims(
            from: localConfig.tree,
            into: incoming.tree
        )
        self.localConfig = mergedIncoming
        persistLocalConfig(mergedIncoming)
        return .replacedWithHigherVersion(
            previousVersion: localConfig.version,
            appliedVersion: mergedIncoming.version
        )
    }

    @discardableResult
    func converge(with payload: Data) throws -> TreeSyncConvergenceResult {
        let incoming = try JSONDecoder().decode(NetworkConfig.self, from: payload)
        return converge(with: incoming)
    }

    func join(network: DiscoveredNetwork, pin: String?) async throws -> NetworkConfig {
        NSLog("[Join] TreeSyncService.join — fetching config from peer %@", network.peerID.uuidString)
        let remoteConfig: NetworkConfig
        do {
            remoteConfig = try await meshService.fetchNetworkConfig(from: network.peerID)
            NSLog("[Join] Received config — networkID: %@, version: %d, requiresPIN: %@",
                  remoteConfig.networkID.uuidString, remoteConfig.version,
                  remoteConfig.requiresPIN ? "yes" : "no")
        } catch {
            NSLog("[Join] ❌ fetchNetworkConfig failed: %@", error.localizedDescription)
            throw TreeSyncJoinError.treeConfigUnavailable
        }

        // NOTE: network.networkID is a proxy (== peerID) because BLE advertisements cannot
        // carry the real networkID — only LocalName and ServiceUUIDs are allowed by CoreBluetooth.
        // The real networkID comes from the GATT treeConfig read we just completed.
        // We do NOT compare them; remoteConfig.networkID is the authoritative value.
        NSLog("[Join] Using real networkID from GATT config: %@ (peer BT ID was: %@)",
              remoteConfig.networkID.uuidString, network.peerID.uuidString)

        if remoteConfig.requiresPIN {
            guard let pin, !pin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NSLog("[Join] ❌ PIN required but not provided")
                throw TreeSyncJoinError.pinRequired
            }

            guard remoteConfig.isValidPIN(pin) else {
                NSLog("[Join] ❌ PIN validation failed")
                throw TreeSyncJoinError.invalidPIN
            }
            NSLog("[Join] PIN validated ✅")
        }

        let keyMaterial = NetworkEncryptionService.keyMaterial(
            pinHash: remoteConfig.pinHash ?? NetworkConfig.hashPIN(pin),
            networkID: remoteConfig.networkID
        )

        if let wrappedSessionKey = remoteConfig.encryptedSessionKey {
            do {
                try meshService.activateSessionKey(
                    networkID: remoteConfig.networkID,
                    wrappedSessionKey: wrappedSessionKey,
                    keyMaterial: keyMaterial
                )
                NSLog("[Join] Session key activated from wrapped key ✅")
            } catch {
                NSLog("[Join] ❌ Failed to activate session key: %@", error.localizedDescription)
                if remoteConfig.requiresPIN {
                    throw TreeSyncJoinError.invalidPIN
                }
                throw TreeSyncJoinError.treeConfigUnavailable
            }
        } else {
            meshService.activateDeterministicSessionKey(
                networkID: remoteConfig.networkID,
                keyMaterial: keyMaterial
            )
            NSLog("[Join] Deterministic session key activated ✅")
        }

        localConfig = remoteConfig
        persistLocalConfig(remoteConfig)
        NSLog("[Join] ✅ TreeSyncService.join complete — '%@' v%d", remoteConfig.networkName, remoteConfig.version)
        return remoteConfig
    }

    private func scheduleDisconnectAutoReparent(for peerID: UUID) {
        let disconnectedOwnerID = peerID.uuidString
        guard let localConfig,
              !Self.claimedNodeIDs(by: disconnectedOwnerID, in: localConfig.tree).isEmpty else {
            return
        }

        cancelDisconnectTask(for: peerID)
        disconnectReparentTasks[peerID] = Task { [weak self] in
            guard let self else {
                return
            }

            let timeoutNanoseconds = UInt64(self.disconnectTimeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            self.performDisconnectAutoReparentIfNeeded(for: peerID)
        }
    }

    private func cancelDisconnectTask(for peerID: UUID) {
        disconnectReparentTasks.removeValue(forKey: peerID)?.cancel()
    }

    private func performDisconnectAutoReparentIfNeeded(for peerID: UUID) {
        disconnectReparentTasks[peerID] = nil

        guard meshService.connectionState(for: peerID) == .disconnected,
              var config = localConfig else {
            return
        }

        let disconnectedOwnerID = peerID.uuidString
        let disconnectedNodeIDs = Self.claimedNodeIDs(by: disconnectedOwnerID, in: config.tree)
        guard !disconnectedNodeIDs.isEmpty else {
            return
        }

        var didMutate = false

        for disconnectedNodeID in disconnectedNodeIDs {
            guard let targetAncestorID = nearestConnectedAncestor(
                above: disconnectedNodeID,
                in: config.tree
            ) else {
                continue
            }

            let childNodeIDs = Self.childNodeIDs(of: disconnectedNodeID, in: config.tree)
            guard !childNodeIDs.isEmpty else {
                continue
            }

            for childNodeID in childNodeIDs {
                guard Self.moveNode(
                    nodeID: childNodeID,
                    newParentID: targetAncestorID,
                    in: &config.tree
                ) else {
                    continue
                }

                config.version += 1
                didMutate = true
                publishTreeUpdate(changedNodeID: childNodeID, in: config)
            }
        }

        guard didMutate else {
            return
        }

        setLocalConfig(config)
    }

    private func nearestConnectedAncestor(above nodeID: String, in tree: TreeNode) -> String? {
        var candidateAncestorID = TreeHelpers.parent(of: nodeID, in: tree)?.id

        while let ancestorID = candidateAncestorID {
            guard let ancestorNode = Self.findNode(withID: ancestorID, in: tree) else {
                return nil
            }

            if isConnected(node: ancestorNode) {
                return ancestorID
            }

            candidateAncestorID = TreeHelpers.parent(of: ancestorID, in: tree)?.id
        }

        return nil
    }

    private func isConnected(node: TreeNode) -> Bool {
        guard let ownerID = node.claimedBy?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ownerID.isEmpty else {
            return true
        }

        guard let peerID = UUID(uuidString: ownerID) else {
            return true
        }

        return meshService.connectionState(for: peerID) == .connected
    }

    private func publishTreeUpdate(changedNodeID: String, in config: NetworkConfig) {
        let parentID = TreeHelpers.parent(of: changedNodeID, in: config.tree)?.id
        let treeLevel = TreeHelpers.level(of: changedNodeID, in: config.tree) ?? 0
        let treeUpdate = Message.make(
            type: .treeUpdate,
            senderID: config.createdBy,
            senderRole: "organiser",
            parentID: parentID,
            treeLevel: treeLevel,
            ttl: defaultTTL,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            tree: config.tree,
            networkVersion: config.version
        )
        meshService.publish(treeUpdate)
    }

    private func persistLocalConfig(_ config: NetworkConfig?) {
        guard let configStore else {
            return
        }

        if let config {
            try? configStore.save(config)
        } else {
            configStore.clear()
        }
    }

    private static func treeByPreservingClaims(from localTree: TreeNode, into incomingTree: TreeNode) -> TreeNode {
        var mergedTree = incomingTree
        let localClaims = claimedNodeMap(in: localTree)
        applyClaims(localClaims, to: &mergedTree)
        return mergedTree
    }

    private static func claimedNodeMap(in tree: TreeNode) -> [String: String] {
        var claims: [String: String] = [:]
        collectClaims(in: tree, into: &claims)
        return claims
    }

    private static func collectClaims(in tree: TreeNode, into claims: inout [String: String]) {
        if let owner = tree.claimedBy, !owner.isEmpty {
            claims[tree.id] = owner
        }

        for child in tree.children {
            collectClaims(in: child, into: &claims)
        }
    }

    private static func applyClaims(_ localClaims: [String: String], to tree: inout TreeNode) {
        if (tree.claimedBy == nil || tree.claimedBy?.isEmpty == true),
           let preservedClaim = localClaims[tree.id],
           !preservedClaim.isEmpty {
            tree.claimedBy = preservedClaim
        }

        for index in tree.children.indices {
            applyClaims(localClaims, to: &tree.children[index])
        }
    }

    private static func claimedNodeIDs(by ownerID: String, in tree: TreeNode) -> [String] {
        var claimedNodeIDs: [String] = []
        collectClaimedNodeIDs(by: ownerID, in: tree, into: &claimedNodeIDs)
        return claimedNodeIDs
    }

    private static func collectClaimedNodeIDs(
        by ownerID: String,
        in tree: TreeNode,
        into collection: inout [String]
    ) {
        if tree.claimedBy == ownerID {
            collection.append(tree.id)
        }

        for child in tree.children {
            collectClaimedNodeIDs(by: ownerID, in: child, into: &collection)
        }
    }

    private static func childNodeIDs(of parentNodeID: String, in tree: TreeNode) -> [String] {
        findNode(withID: parentNodeID, in: tree)?.children.map(\.id) ?? []
    }

    private static func findNode(withID nodeID: String, in tree: TreeNode) -> TreeNode? {
        if tree.id == nodeID {
            return tree
        }

        for child in tree.children {
            if let found = findNode(withID: nodeID, in: child) {
                return found
            }
        }

        return nil
    }

    private static func moveNode(nodeID: String, newParentID: String, in tree: inout TreeNode) -> Bool {
        guard nodeID != tree.id, nodeID != newParentID else {
            return false
        }

        guard let nodeToMove = findNode(withID: nodeID, in: tree),
              findNode(withID: newParentID, in: tree) != nil,
              !treeContainsNode(withID: newParentID, in: nodeToMove) else {
            return false
        }

        let originalParentID = TreeHelpers.parent(of: nodeID, in: tree)?.id
        guard let detachedNode = detachNode(nodeID: nodeID, from: &tree) else {
            return false
        }

        guard appendChild(detachedNode, toParentID: newParentID, in: &tree) else {
            if let originalParentID {
                _ = appendChild(detachedNode, toParentID: originalParentID, in: &tree)
            }
            return false
        }

        return true
    }

    private static func detachNode(nodeID: String, from tree: inout TreeNode) -> TreeNode? {
        if let index = tree.children.firstIndex(where: { $0.id == nodeID }) {
            return tree.children.remove(at: index)
        }

        for index in tree.children.indices {
            if let detachedNode = detachNode(nodeID: nodeID, from: &tree.children[index]) {
                return detachedNode
            }
        }

        return nil
    }

    private static func appendChild(_ child: TreeNode, toParentID parentID: String, in tree: inout TreeNode) -> Bool {
        if tree.id == parentID {
            tree.children.append(child)
            return true
        }

        for index in tree.children.indices {
            if appendChild(child, toParentID: parentID, in: &tree.children[index]) {
                return true
            }
        }

        return false
    }

    private static func treeContainsNode(withID nodeID: String, in tree: TreeNode) -> Bool {
        if tree.id == nodeID {
            return true
        }

        for child in tree.children {
            if treeContainsNode(withID: nodeID, in: child) {
                return true
            }
        }

        return false
    }
}

@MainActor
final class NetworkDiscoveryService: ObservableObject {
    @Published private(set) var nearbyNetworks: [DiscoveredNetwork] = []
    @Published private(set) var isScanning = false

    private let meshService: BluetoothMeshService
    private var scanTimeoutTask: Task<Void, Never>?

    init(meshService: BluetoothMeshService = BluetoothMeshService()) {
        self.meshService = meshService
    }

    deinit {
        scanTimeoutTask?.cancel()
    }

    func startScanning(timeout: TimeInterval = 10) {
        NSLog("[Discovery] startScanning — timeout: %.0fs", timeout)
        nearbyNetworks = []
        isScanning = true

        meshService.onNetworkDiscovered = { [weak self] peerID, summary in
            Task { @MainActor in
                NSLog("[Discovery] Network discovered — '%@' from peer %@ (slots: %d, PIN: %@)",
                      summary.networkName, peerID.uuidString, summary.openSlotCount,
                      summary.requiresPIN ? "yes" : "no")
                self?.upsert(
                    DiscoveredNetwork(
                        peerID: peerID,
                        networkID: summary.networkID,
                        networkName: summary.networkName,
                        openSlotCount: summary.openSlotCount,
                        requiresPIN: summary.requiresPIN
                    )
                )
            }
        }

        meshService.start()
        scanTimeoutTask?.cancel()

        let timeoutNanoseconds = UInt64(max(timeout, 0) * 1_000_000_000)
        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.isScanning = false
            }
        }
    }

    func stopScanning() {
        isScanning = false
        scanTimeoutTask?.cancel()
        scanTimeoutTask = nil
        meshService.onNetworkDiscovered = nil
    }

    private func upsert(_ network: DiscoveredNetwork) {
        if let index = nearbyNetworks.firstIndex(where: { $0.peerID == network.peerID }) {
            nearbyNetworks[index] = network
        } else {
            nearbyNetworks.append(network)
        }

        nearbyNetworks.sort { lhs, rhs in
            if lhs.openSlotCount == rhs.openSlotCount {
                return lhs.networkName.localizedCaseInsensitiveCompare(rhs.networkName) == .orderedAscending
            }
            return lhs.openSlotCount > rhs.openSlotCount
        }
    }
}

enum ClaimRejectionReason: String, Codable, Equatable, Sendable {
    case alreadyClaimed = "already_claimed"
    case organiserWins = "organiser_wins"
    case nodeNotFound = "node_not_found"
}

enum RoleClaimResult: Equatable, Sendable {
    case claimed(nodeID: String)
    case released(nodeID: String)
    case rejected(reason: ClaimRejectionReason)
    case noActiveClaim
    case unavailable
}

enum PromoteValidationError: Error, Equatable, Sendable {
    case networkUnavailable
    case nodeNotFound
    case targetUnclaimed
}

@MainActor
final class RoleClaimService: ObservableObject {
    @Published private(set) var activeClaimNodeID: String?
    @Published private(set) var lastClaimRejection: ClaimRejectionReason?
    @Published private(set) var networkConfig: NetworkConfig?
    @Published private(set) var requiresRoleReselection = false
    @Published private(set) var roleReselectionNotification: String?

    private let meshService: BluetoothMeshService
    private let treeSyncService: TreeSyncService
    private let localDeviceID: String
    private let disconnectTimeout: TimeInterval
    private var disconnectReleaseTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellables: Set<AnyCancellable> = []

    private let defaultTTL = 8

    init(
        meshService: BluetoothMeshService,
        treeSyncService: TreeSyncService,
        localDeviceID: String,
        disconnectTimeout: TimeInterval = 60
    ) {
        self.meshService = meshService
        self.treeSyncService = treeSyncService
        self.localDeviceID = localDeviceID
        self.disconnectTimeout = max(0, disconnectTimeout)

        treeSyncService.$localConfig
            .receive(on: RunLoop.main)
            .sink { [weak self] config in
                self?.applyLocalConfigSnapshot(config)
            }
            .store(in: &cancellables)

        applyLocalConfigSnapshot(treeSyncService.localConfig)
    }

    deinit {
        disconnectReleaseTasks.values.forEach { $0.cancel() }
    }

    var localNodeIdentity: String {
        localDeviceID
    }

    var isOrganiser: Bool {
        networkConfig?.createdBy == localDeviceID
    }

    func claim(nodeID: String) -> RoleClaimResult {
        NSLog("[Role] Attempting to claim node '%@'", nodeID)
        guard var config = networkConfig else {
            NSLog("[Role] ❌ Claim failed — no network config")
            return .unavailable
        }

        guard let node = findNode(withID: nodeID, in: config.tree) else {
            NSLog("[Role] ❌ Claim failed — node not found")
            lastClaimRejection = .nodeNotFound
            return .rejected(reason: .nodeNotFound)
        }

        if let existingClaim = node.claimedBy, !existingClaim.isEmpty, existingClaim != localDeviceID {
            if config.createdBy == localDeviceID {
                guard updateClaim(nodeID: nodeID, claimedBy: localDeviceID, in: &config.tree) else {
                    return .unavailable
                }

                NSLog("[Role] ✅ Organiser override — claimed '%@' (was held by %@)", node.label, existingClaim)
                applyUpdatedConfig(config)
                publishClaim(nodeID: nodeID, claimantID: localDeviceID, in: config)
                publishClaimRejected(
                    nodeID: nodeID,
                    targetDeviceID: existingClaim,
                    reason: .organiserWins,
                    in: config
                )
                lastClaimRejection = nil
                clearRoleReselectionState()
                return .claimed(nodeID: nodeID)
            }

            NSLog("[Role] ❌ Claim rejected — node '%@' already claimed by %@", node.label, existingClaim)
            lastClaimRejection = .alreadyClaimed
            return .rejected(reason: .alreadyClaimed)
        }

        guard updateClaim(nodeID: nodeID, claimedBy: localDeviceID, in: &config.tree) else {
            return .unavailable
        }

        NSLog("[Role] ✅ Claimed node '%@' (%@)", node.label, nodeID)
        applyUpdatedConfig(config)
        publishClaim(nodeID: nodeID, claimantID: localDeviceID, in: config)
        lastClaimRejection = nil
        clearRoleReselectionState()
        return .claimed(nodeID: nodeID)
    }

    func releaseActiveClaim() -> RoleClaimResult {
        guard var config = networkConfig else {
            return .unavailable
        }

        guard let claimedNodeID = activeClaimNodeID ?? firstClaimedNodeID(by: localDeviceID, in: config.tree) else {
            return .noActiveClaim
        }

        guard updateClaim(nodeID: claimedNodeID, claimedBy: nil, in: &config.tree) else {
            return .noActiveClaim
        }

        applyUpdatedConfig(config)
        publishRelease(nodeID: claimedNodeID, releasedBy: localDeviceID, in: config)
        lastClaimRejection = nil
        clearRoleReselectionState()
        return .released(nodeID: claimedNodeID)
    }

    func validatePromoteTarget(nodeID: String) throws {
        guard let config = networkConfig else {
            throw PromoteValidationError.networkUnavailable
        }

        guard let node = findNode(withID: nodeID, in: config.tree) else {
            throw PromoteValidationError.nodeNotFound
        }

        guard let claimant = node.claimedBy, !claimant.isEmpty else {
            throw PromoteValidationError.targetUnclaimed
        }
    }

    @discardableResult
    func addNode(parentID: String, label: String) -> TreeNode? {
        guard isOrganiser, var config = networkConfig else {
            return nil
        }

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            return nil
        }

        guard let createdNode = insertChild(parentID: parentID, label: trimmedLabel, in: &config.tree) else {
            return nil
        }

        config.version += 1
        applyUpdatedConfig(config)
        publishTreeUpdate(changedNodeID: createdNode.id, in: config)
        return createdNode
    }

    @discardableResult
    func removeNode(nodeID: String) -> Bool {
        guard isOrganiser, var config = networkConfig else {
            return false
        }

        guard nodeID != config.tree.id else {
            return false
        }

        guard removeTreeNode(nodeID: nodeID, from: &config.tree) != nil else {
            return false
        }

        config.version += 1
        applyUpdatedConfig(config)
        publishTreeUpdate(changedNodeID: nil, in: config)
        return true
    }

    @discardableResult
    func renameNode(nodeID: String, newLabel: String) -> Bool {
        guard isOrganiser, var config = networkConfig else {
            return false
        }

        let trimmedLabel = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            return false
        }

        guard renameTreeNode(nodeID: nodeID, newLabel: trimmedLabel, in: &config.tree) else {
            return false
        }

        config.version += 1
        applyUpdatedConfig(config)
        publishTreeUpdate(changedNodeID: nodeID, in: config)
        return true
    }

    @discardableResult
    func moveNode(nodeID: String, newParentID: String) -> Bool {
        guard isOrganiser, var config = networkConfig else {
            return false
        }

        guard nodeID != config.tree.id, nodeID != newParentID else {
            return false
        }

        guard let nodeToMove = findNode(withID: nodeID, in: config.tree),
              findNode(withID: newParentID, in: config.tree) != nil,
              !treeContainsNode(withID: newParentID, in: nodeToMove) else {
            return false
        }

        let originalParentID = TreeHelpers.parent(of: nodeID, in: config.tree)?.id
        guard let detachedNode = removeTreeNode(nodeID: nodeID, from: &config.tree) else {
            return false
        }

        guard appendChild(detachedNode, toParentID: newParentID, in: &config.tree) else {
            if let originalParentID {
                _ = appendChild(detachedNode, toParentID: originalParentID, in: &config.tree)
            }
            return false
        }

        config.version += 1
        applyUpdatedConfig(config)
        publishTreeUpdate(changedNodeID: nodeID, in: config)
        return true
    }

    @discardableResult
    func reorderNode(nodeID: String, beforeSiblingID: String) -> Bool {
        guard isOrganiser, var config = networkConfig else {
            return false
        }

        guard nodeID != beforeSiblingID,
              nodeID != config.tree.id,
              beforeSiblingID != config.tree.id else {
            return false
        }

        guard let sourceParentID = TreeHelpers.parent(of: nodeID, in: config.tree)?.id,
              let targetParentID = TreeHelpers.parent(of: beforeSiblingID, in: config.tree)?.id,
              sourceParentID == targetParentID else {
            return false
        }

        guard reorderSiblingNode(nodeID: nodeID, beforeSiblingID: beforeSiblingID, in: &config.tree) else {
            return false
        }

        config.version += 1
        applyUpdatedConfig(config)
        publishTreeUpdate(changedNodeID: nodeID, in: config)
        return true
    }

    @discardableResult
    func promote(nodeID: String) -> Bool {
        guard isOrganiser, var config = networkConfig else {
            return false
        }

        guard let targetNode = findNode(withID: nodeID, in: config.tree),
              let promotedDeviceID = targetNode.claimedBy,
              !promotedDeviceID.isEmpty else {
            return false
        }

        let senderRoleAtPromotion = senderRole(for: localDeviceID, in: config)
        guard config.createdBy != promotedDeviceID else {
            return false
        }

        config.createdBy = promotedDeviceID
        config.version += 1
        applyUpdatedConfig(config)
        publishPromote(
            nodeID: nodeID,
            senderRole: senderRoleAtPromotion,
            in: config
        )
        return true
    }

    func handleIncomingMessage(_ message: Message) {
        switch message.type {
        case .claim:
            handleIncomingClaim(message)
        case .release:
            handleIncomingRelease(message)
        case .treeUpdate:
            handleIncomingTreeUpdate(message)
        case .promote:
            handleIncomingPromote(message)
        case .claimRejected:
            handleIncomingClaimRejected(message)
        default:
            break
        }
    }

    func handlePeerStateChange(peerID: UUID, state: PeerConnectionState) {
        switch state {
        case .connected:
            cancelDisconnectTask(for: peerID)

        case .disconnected:
            guard isOrganiser else {
                return
            }
            scheduleDisconnectAutoRelease(for: peerID)
        }
    }

    private func handleIncomingClaim(_ message: Message) {
        guard let nodeID = message.payload.claimedNodeID, var config = networkConfig else {
            return
        }

        guard let currentNode = findNode(withID: nodeID, in: config.tree) else {
            if config.createdBy == localDeviceID {
                publishClaimRejected(
                    nodeID: nodeID,
                    targetDeviceID: message.senderID,
                    reason: .nodeNotFound,
                    in: config
                )
            }
            return
        }

        let senderID = message.senderID
        let organiserID = config.createdBy
        let existingClaim = currentNode.claimedBy

        if existingClaim == senderID {
            return
        }

        if existingClaim == nil || existingClaim?.isEmpty == true {
            guard updateClaim(nodeID: nodeID, claimedBy: senderID, in: &config.tree) else {
                return
            }
            applyUpdatedConfig(config)
            return
        }

        guard let existingClaim else {
            return
        }

        if senderID == organiserID && existingClaim != organiserID {
            guard updateClaim(nodeID: nodeID, claimedBy: senderID, in: &config.tree) else {
                return
            }
            applyUpdatedConfig(config)
            return
        }

        guard localDeviceID == organiserID else {
            return
        }

        if existingClaim == organiserID {
            publishClaimRejected(
                nodeID: nodeID,
                targetDeviceID: senderID,
                reason: .organiserWins,
                in: config
            )
            return
        }

        publishClaimRejected(
            nodeID: nodeID,
            targetDeviceID: senderID,
            reason: .alreadyClaimed,
            in: config
        )
    }

    private func handleIncomingRelease(_ message: Message) {
        guard let nodeID = message.payload.claimedNodeID, var config = networkConfig else {
            return
        }

        guard let currentNode = findNode(withID: nodeID, in: config.tree),
              let currentClaim = currentNode.claimedBy,
              !currentClaim.isEmpty else {
            return
        }

        let senderID = message.senderID
        let organiserID = config.createdBy
        guard senderID == currentClaim || senderID == organiserID else {
            return
        }

        guard updateClaim(nodeID: nodeID, claimedBy: nil, in: &config.tree) else {
            return
        }
        applyUpdatedConfig(config)
    }

    private func handleIncomingTreeUpdate(_ message: Message) {
        guard let incomingTree = message.payload.tree,
              let incomingVersion = message.payload.networkVersion,
              var incomingConfig = networkConfig else {
            return
        }

        let previouslyClaimedNodeID = activeClaimNodeID
        incomingConfig.tree = incomingTree
        incomingConfig.version = incomingVersion

        _ = treeSyncService.converge(with: incomingConfig)

        guard let appliedConfig = treeSyncService.localConfig else {
            return
        }

        applyLocalConfigSnapshot(appliedConfig)

        guard let previouslyClaimedNodeID,
              findNode(withID: previouslyClaimedNodeID, in: appliedConfig.tree) == nil else {
            return
        }

        activeClaimNodeID = nil
        lastClaimRejection = .nodeNotFound
        requiresRoleReselection = true
        roleReselectionNotification = "Your claimed role was removed from the tree."
    }

    private func handleIncomingPromote(_ message: Message) {
        guard let targetNodeID = message.payload.targetNodeID,
              let promotedVersion = message.payload.networkVersion,
              var config = networkConfig,
              let targetNode = findNode(withID: targetNodeID, in: config.tree),
              let promotedDeviceID = targetNode.claimedBy,
              !promotedDeviceID.isEmpty else {
            return
        }

        let currentVersion = config.version
        guard promotedVersion > currentVersion else {
            return
        }

        config.createdBy = promotedDeviceID
        config.version = promotedVersion
        applyUpdatedConfig(config)
    }

    private func handleIncomingClaimRejected(_ message: Message) {
        guard message.payload.targetNodeID == localDeviceID else {
            return
        }

        if let rawReason = message.payload.rejectionReason,
           let reason = ClaimRejectionReason(rawValue: rawReason) {
            lastClaimRejection = reason
        } else {
            lastClaimRejection = .alreadyClaimed
        }

        guard let nodeID = message.payload.claimedNodeID, var config = networkConfig else {
            return
        }

        guard let node = findNode(withID: nodeID, in: config.tree),
              node.claimedBy == localDeviceID else {
            return
        }

        guard updateClaim(nodeID: nodeID, claimedBy: nil, in: &config.tree) else {
            return
        }
        applyUpdatedConfig(config)
    }

    private func scheduleDisconnectAutoRelease(for peerID: UUID) {
        let disconnectedOwnerID = peerID.uuidString
        guard let config = networkConfig,
              !claimedNodeIDs(by: disconnectedOwnerID, in: config.tree).isEmpty else {
            return
        }

        cancelDisconnectTask(for: peerID)
        disconnectReleaseTasks[peerID] = Task { [weak self] in
            guard let self else {
                return
            }

            let timeoutNanoseconds = UInt64(self.disconnectTimeout * 1_000_000_000)
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else {
                return
            }
            self.performDisconnectAutoReleaseIfNeeded(for: peerID)
        }
    }

    private func cancelDisconnectTask(for peerID: UUID) {
        disconnectReleaseTasks.removeValue(forKey: peerID)?.cancel()
    }

    private func performDisconnectAutoReleaseIfNeeded(for peerID: UUID) {
        disconnectReleaseTasks[peerID] = nil

        guard meshService.connectionState(for: peerID) == .disconnected,
              var config = networkConfig,
              config.createdBy == localDeviceID else {
            return
        }

        let disconnectedOwnerID = peerID.uuidString
        let nodesToRelease = claimedNodeIDs(by: disconnectedOwnerID, in: config.tree)
        guard !nodesToRelease.isEmpty else {
            return
        }

        for nodeID in nodesToRelease {
            guard updateClaim(nodeID: nodeID, claimedBy: nil, in: &config.tree) else {
                continue
            }
            publishRelease(nodeID: nodeID, releasedBy: disconnectedOwnerID, in: config)
        }

        applyUpdatedConfig(config)
    }

    private func publishClaim(nodeID: String, claimantID: String, in config: NetworkConfig) {
        let claimMessage = Message.make(
            type: .claim,
            senderID: claimantID,
            senderRole: senderRole(for: claimantID, in: config),
            parentID: TreeHelpers.parent(of: nodeID, in: config.tree)?.id,
            treeLevel: TreeHelpers.level(of: nodeID, in: config.tree) ?? 0,
            ttl: defaultTTL,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            claimedNodeID: nodeID
        )
        meshService.publish(claimMessage)
    }

    private func publishRelease(nodeID: String, releasedBy: String, in config: NetworkConfig) {
        let releaseMessage = Message.make(
            type: .release,
            senderID: releasedBy,
            senderRole: senderRole(for: releasedBy, in: config),
            parentID: TreeHelpers.parent(of: nodeID, in: config.tree)?.id,
            treeLevel: TreeHelpers.level(of: nodeID, in: config.tree) ?? 0,
            ttl: defaultTTL,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            claimedNodeID: nodeID
        )
        meshService.publish(releaseMessage)
    }

    private func publishClaimRejected(
        nodeID: String,
        targetDeviceID: String,
        reason: ClaimRejectionReason,
        in config: NetworkConfig
    ) {
        let rejectedMessage = Message.make(
            type: .claimRejected,
            senderID: localDeviceID,
            senderRole: senderRole(for: localDeviceID, in: config),
            parentID: TreeHelpers.parent(of: nodeID, in: config.tree)?.id,
            treeLevel: TreeHelpers.level(of: nodeID, in: config.tree) ?? 0,
            ttl: defaultTTL,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            claimedNodeID: nodeID,
            targetNodeID: targetDeviceID,
            rejectionReason: reason.rawValue
        )
        meshService.publish(rejectedMessage)
    }

    private func publishTreeUpdate(changedNodeID: String?, in config: NetworkConfig) {
        let parentID = changedNodeID.flatMap { TreeHelpers.parent(of: $0, in: config.tree)?.id }
        let treeLevel = changedNodeID.flatMap { TreeHelpers.level(of: $0, in: config.tree) } ?? 0
        let treeUpdate = Message.make(
            type: .treeUpdate,
            senderID: localDeviceID,
            senderRole: senderRole(for: localDeviceID, in: config),
            parentID: parentID,
            treeLevel: treeLevel,
            ttl: defaultTTL,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            tree: config.tree,
            networkVersion: config.version
        )
        meshService.publish(treeUpdate)
    }

    private func publishPromote(nodeID: String, senderRole: String, in config: NetworkConfig) {
        let parentID = TreeHelpers.parent(of: nodeID, in: config.tree)?.id
        let treeLevel = TreeHelpers.level(of: nodeID, in: config.tree) ?? 0
        let promoteMessage = Message.make(
            type: .promote,
            senderID: localDeviceID,
            senderRole: senderRole,
            parentID: parentID,
            treeLevel: treeLevel,
            ttl: defaultTTL,
            encrypted: false,
            latitude: nil,
            longitude: nil,
            accuracy: nil,
            targetNodeID: nodeID,
            networkVersion: config.version
        )
        meshService.publish(promoteMessage)
    }

    private func senderRole(for senderID: String, in config: NetworkConfig) -> String {
        senderID == config.createdBy ? "organiser" : "participant"
    }

    private func applyLocalConfigSnapshot(_ config: NetworkConfig?) {
        networkConfig = config
        guard let config else {
            activeClaimNodeID = nil
            return
        }
        activeClaimNodeID = firstClaimedNodeID(by: localDeviceID, in: config.tree)
        if activeClaimNodeID != nil {
            clearRoleReselectionState()
        }
    }

    private func applyUpdatedConfig(_ config: NetworkConfig) {
        treeSyncService.setLocalConfig(config)
        applyLocalConfigSnapshot(config)
    }

    private func clearRoleReselectionState() {
        requiresRoleReselection = false
        roleReselectionNotification = nil
    }

    @discardableResult
    private func insertChild(parentID: String, label: String, in tree: inout TreeNode) -> TreeNode? {
        if tree.id == parentID {
            let createdNode = TreeNode(
                id: UUID().uuidString,
                label: label,
                claimedBy: nil,
                children: []
            )
            tree.children.append(createdNode)
            return createdNode
        }

        for index in tree.children.indices {
            if let createdNode = insertChild(parentID: parentID, label: label, in: &tree.children[index]) {
                return createdNode
            }
        }

        return nil
    }

    @discardableResult
    private func removeTreeNode(nodeID: String, from tree: inout TreeNode) -> TreeNode? {
        if let index = tree.children.firstIndex(where: { $0.id == nodeID }) {
            return tree.children.remove(at: index)
        }

        for index in tree.children.indices {
            if let removed = removeTreeNode(nodeID: nodeID, from: &tree.children[index]) {
                return removed
            }
        }

        return nil
    }

    @discardableResult
    private func renameTreeNode(nodeID: String, newLabel: String, in tree: inout TreeNode) -> Bool {
        if tree.id == nodeID {
            tree.label = newLabel
            return true
        }

        for index in tree.children.indices {
            if renameTreeNode(nodeID: nodeID, newLabel: newLabel, in: &tree.children[index]) {
                return true
            }
        }

        return false
    }

    @discardableResult
    private func appendChild(_ child: TreeNode, toParentID parentID: String, in tree: inout TreeNode) -> Bool {
        if tree.id == parentID {
            tree.children.append(child)
            return true
        }

        for index in tree.children.indices {
            if appendChild(child, toParentID: parentID, in: &tree.children[index]) {
                return true
            }
        }

        return false
    }

    private func treeContainsNode(withID nodeID: String, in tree: TreeNode) -> Bool {
        if tree.id == nodeID {
            return true
        }

        for child in tree.children {
            if treeContainsNode(withID: nodeID, in: child) {
                return true
            }
        }

        return false
    }

    @discardableResult
    private func reorderSiblingNode(nodeID: String, beforeSiblingID: String, in tree: inout TreeNode) -> Bool {
        let childIDs = tree.children.map(\.id)
        if let fromIndex = childIDs.firstIndex(of: nodeID),
           let toIndex = childIDs.firstIndex(of: beforeSiblingID) {
            guard fromIndex != toIndex else {
                return false
            }

            let movingNode = tree.children.remove(at: fromIndex)
            let destinationIndex = fromIndex < toIndex ? max(0, toIndex - 1) : toIndex
            tree.children.insert(movingNode, at: destinationIndex)
            return true
        }

        for index in tree.children.indices {
            if reorderSiblingNode(nodeID: nodeID, beforeSiblingID: beforeSiblingID, in: &tree.children[index]) {
                return true
            }
        }

        return false
    }

    private func findNode(withID nodeID: String, in tree: TreeNode) -> TreeNode? {
        if tree.id == nodeID {
            return tree
        }

        for child in tree.children {
            if let found = findNode(withID: nodeID, in: child) {
                return found
            }
        }

        return nil
    }

    @discardableResult
    private func updateClaim(nodeID: String, claimedBy: String?, in tree: inout TreeNode) -> Bool {
        if tree.id == nodeID {
            tree.claimedBy = claimedBy
            return true
        }

        for index in tree.children.indices {
            if updateClaim(nodeID: nodeID, claimedBy: claimedBy, in: &tree.children[index]) {
                return true
            }
        }

        return false
    }

    private func firstClaimedNodeID(by ownerID: String, in tree: TreeNode) -> String? {
        if tree.claimedBy == ownerID {
            return tree.id
        }

        for child in tree.children {
            if let claimedNodeID = firstClaimedNodeID(by: ownerID, in: child) {
                return claimedNodeID
            }
        }

        return nil
    }

    private func claimedNodeIDs(by ownerID: String, in tree: TreeNode) -> [String] {
        var claimedNodeIDs: [String] = []
        collectClaimedNodeIDs(by: ownerID, in: tree, into: &claimedNodeIDs)
        return claimedNodeIDs
    }

    private func collectClaimedNodeIDs(by ownerID: String, in tree: TreeNode, into collection: inout [String]) {
        if tree.claimedBy == ownerID {
            collection.append(tree.id)
        }

        for child in tree.children {
            collectClaimedNodeIDs(by: ownerID, in: child, into: &collection)
        }
    }
}

// MARK: - Log helpers

private extension CBManagerState {
    var logDescription: String {
        switch self {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}
