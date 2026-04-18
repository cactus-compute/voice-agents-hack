import Foundation
import ZIPFoundation
import cactus

public typealias CactusModelT = UnsafeMutableRawPointer
public typealias CactusIndexT = UnsafeMutableRawPointer
public typealias CactusStreamTranscribeT = UnsafeMutableRawPointer

private let _frameworkInitialized: Void = {
    cactus_set_telemetry_environment("swift", nil, nil)
    if let bundleId = Bundle.main.bundleIdentifier {
        bundleId.withCString { cactus_set_app_id($0) }
    }
}()

private func _err(_ msg: String) -> NSError {
    let e = cactusGetLastError()
    let desc = e.isEmpty ? msg : e
    return NSError(domain: "cactus", code: -1, userInfo: [NSLocalizedDescriptionKey: desc])
}

private class TokenCallbackContext {
    let callback: (String, UInt32) -> Void
    init(callback: @escaping (String, UInt32) -> Void) {
        self.callback = callback
    }
}

private func tokenCallbackBridge(token: UnsafePointer<CChar>?, tokenId: UInt32, userData: UnsafeMutableRawPointer?) {
    guard let token = token, let userData = userData else { return }
    let context = Unmanaged<TokenCallbackContext>.fromOpaque(userData).takeUnretainedValue()
    context.callback(String(cString: token), tokenId)
}

private let _defaultBufferSize = 65536

// MARK: - Telemetry

public func cactusGetLastError() -> String {
    return String(cString: cactus_get_last_error())
}

public func cactusSetTelemetryEnvironment(_ path: String) {
    cactus_set_telemetry_environment(nil, path, nil)
}

public func cactusSetAppId(_ appId: String) {
    appId.withCString { cactus_set_app_id($0) }
}

public func cactusTelemetryFlush() {
    cactus_telemetry_flush()
}

public func cactusTelemetryShutdown() {
    cactus_telemetry_shutdown()
}

// MARK: - Model lifecycle

public func cactusInit(_ modelPath: String, _ corpusDir: String?, _ cacheIndex: Bool) throws -> CactusModelT {
    _ = _frameworkInitialized
    guard let h = cactus_init(modelPath, corpusDir, cacheIndex) else {
        throw _err("Failed to initialize model")
    }
    return h
}

public func cactusDestroy(_ model: CactusModelT) {
    cactus_destroy(model)
}

public func cactusReset(_ model: CactusModelT) {
    cactus_reset(model)
}

public func cactusStop(_ model: CactusModelT) {
    cactus_stop(model)
}

// MARK: - Inference

public func cactusComplete(_ model: CactusModelT, _ messagesJson: String, _ optionsJson: String?, _ toolsJson: String?, _ onToken: ((String, UInt32) -> Void)?, _ pcmData: Data? = nil) throws -> String {
    var buffer = [CChar](repeating: 0, count: _defaultBufferSize)

    let callbackContext = onToken.map { TokenCallbackContext(callback: $0) }
    let contextPtr = callbackContext.map { Unmanaged.passUnretained($0).toOpaque() }

    let result: Int32
    if let pcmData = pcmData {
        result = pcmData.withUnsafeBytes { pcmPtr in
            buffer.withUnsafeMutableBufferPointer { bufferPtr in
                cactus_complete(
                    model,
                    messagesJson,
                    bufferPtr.baseAddress,
                    bufferPtr.count,
                    optionsJson,
                    toolsJson,
                    onToken != nil ? tokenCallbackBridge : nil,
                    contextPtr,
                    pcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), pcmData.count
                )
            }
        }
    } else {
        result = buffer.withUnsafeMutableBufferPointer { bufferPtr in
            cactus_complete(
                model,
                messagesJson,
                bufferPtr.baseAddress,
                bufferPtr.count,
                optionsJson,
                toolsJson,
                onToken != nil ? tokenCallbackBridge : nil,
                contextPtr,
                nil, 0
            )
        }
    }

    if result < 0 { throw _err("Completion failed") }
    return String(cString: buffer)
}

public func cactusPrefill(_ model: CactusModelT, _ messagesJson: String, _ optionsJson: String?, _ toolsJson: String?, _ pcmData: Data? = nil) throws -> String {
    var buffer = [CChar](repeating: 0, count: _defaultBufferSize)

    let result: Int32
    if let pcmData = pcmData {
        result = pcmData.withUnsafeBytes { pcmPtr in
            buffer.withUnsafeMutableBufferPointer { bufferPtr in
                cactus_prefill(
                    model,
                    messagesJson,
                    bufferPtr.baseAddress,
                    bufferPtr.count,
                    optionsJson,
                    toolsJson,
                    pcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), pcmData.count
                )
            }
        }
    } else {
        result = buffer.withUnsafeMutableBufferPointer { bufferPtr in
            cactus_prefill(
                model,
                messagesJson,
                bufferPtr.baseAddress,
                bufferPtr.count,
                optionsJson,
                toolsJson,
                nil, 0
            )
        }
    }

    if result < 0 { throw _err("Prefill failed") }
    return String(cString: buffer)
}

public func cactusTokenize(_ model: CactusModelT, _ text: String) throws -> [UInt32] {
    var tokenBuffer = [UInt32](repeating: 0, count: 8192)
    var tokenLen: Int = 0

    let result = tokenBuffer.withUnsafeMutableBufferPointer { bufferPtr in
        cactus_tokenize(model, text, bufferPtr.baseAddress, bufferPtr.count, &tokenLen)
    }

    if result < 0 { throw _err("Tokenization failed") }
    return Array(tokenBuffer.prefix(tokenLen))
}

public func cactusScoreWindow(_ model: CactusModelT, _ tokens: [UInt32], _ start: Int, _ end: Int, _ context: Int) throws -> String {
    var buffer = [CChar](repeating: 0, count: _defaultBufferSize)

    let result = tokens.withUnsafeBufferPointer { tokenPtr in
        buffer.withUnsafeMutableBufferPointer { bufferPtr in
            cactus_score_window(
                model,
                tokenPtr.baseAddress, tokenPtr.count,
                start, end, context,
                bufferPtr.baseAddress, bufferPtr.count
            )
        }
    }

    if result < 0 { throw _err("Score window failed") }
    return String(cString: buffer)
}

public func cactusDetectLanguage(_ model: CactusModelT, _ audioPath: String?, _ optionsJson: String?, _ pcmData: Data?) throws -> String {
    var buffer = [CChar](repeating: 0, count: _defaultBufferSize)

    let result: Int32
    if let pcmData = pcmData {
        result = pcmData.withUnsafeBytes { pcmPtr in
            buffer.withUnsafeMutableBufferPointer { bufferPtr in
                cactus_detect_language(
                    model, audioPath,
                    bufferPtr.baseAddress, bufferPtr.count,
                    optionsJson,
                    pcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), pcmData.count
                )
            }
        }
    } else {
        result = buffer.withUnsafeMutableBufferPointer { bufferPtr in
            cactus_detect_language(model, audioPath, bufferPtr.baseAddress, bufferPtr.count, optionsJson, nil, 0)
        }
    }

    if result < 0 { throw _err("Detect language failed") }
    return String(cString: buffer)
}

public func cactusTranscribe(_ model: CactusModelT, _ audioPath: String?, _ prompt: String?, _ optionsJson: String?, _ onToken: ((String, UInt32) -> Void)?, _ pcmData: Data?) throws -> String {
    var buffer = [CChar](repeating: 0, count: _defaultBufferSize)
    let callbackContext = onToken.map { TokenCallbackContext(callback: $0) }
    let contextPtr = callbackContext.map { Unmanaged.passUnretained($0).toOpaque() }

    let result: Int32
    if let pcmData = pcmData {
        result = pcmData.withUnsafeBytes { pcmPtr in
            buffer.withUnsafeMutableBufferPointer { bufferPtr in
                cactus_transcribe(
                    model, audioPath, prompt,
                    bufferPtr.baseAddress, bufferPtr.count,
                    optionsJson,
                    onToken != nil ? tokenCallbackBridge : nil, contextPtr,
                    pcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), pcmData.count
                )
            }
        }
    } else {
        result = buffer.withUnsafeMutableBufferPointer { bufferPtr in
            cactus_transcribe(
                model, audioPath, prompt,
                bufferPtr.baseAddress, bufferPtr.count,
                optionsJson,
                onToken != nil ? tokenCallbackBridge : nil, contextPtr,
                nil, 0
            )
        }
    }

    if result < 0 { throw _err("Transcription failed") }
    return String(cString: buffer)
}

public func cactusStreamTranscribeStart(_ model: CactusModelT, _ optionsJson: String?) throws -> CactusStreamTranscribeT {
    guard let h = cactus_stream_transcribe_start(model, optionsJson) else {
        throw _err("Failed to create stream transcriber")
    }
    return h
}

public func cactusStreamTranscribeProcess(_ stream: CactusStreamTranscribeT, _ pcmData: Data) throws -> String {
    var buffer = [CChar](repeating: 0, count: _defaultBufferSize)

    let result = pcmData.withUnsafeBytes { pcmPtr in
        buffer.withUnsafeMutableBufferPointer { bufferPtr in
            cactus_stream_transcribe_process(
                stream,
                pcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                pcmData.count,
                bufferPtr.baseAddress,
                bufferPtr.count
            )
        }
    }

    if result < 0 { throw _err("Stream process failed") }
    return String(cString: buffer)
}

public func cactusStreamTranscribeStop(_ stream: CactusStreamTranscribeT) throws -> String {
    var buffer = [CChar](repeating: 0, count: _defaultBufferSize)

    let result = buffer.withUnsafeMutableBufferPointer { bufferPtr in
        cactus_stream_transcribe_stop(stream, bufferPtr.baseAddress, bufferPtr.count)
    }

    if result < 0 { throw _err("Stream stop failed") }
    return String(cString: buffer)
}

public func cactusEmbed(_ model: CactusModelT, _ text: String, _ normalize: Bool) throws -> [Float] {
    var embeddingBuffer = [Float](repeating: 0, count: 4096)
    var embeddingDim: Int = 0

    let result = embeddingBuffer.withUnsafeMutableBufferPointer { bufferPtr in
        cactus_embed(model, text, bufferPtr.baseAddress, bufferPtr.count, &embeddingDim, normalize)
    }

    if result < 0 { throw _err("Embedding failed") }
    return Array(embeddingBuffer.prefix(embeddingDim))
}

public func cactusImageEmbed(_ model: CactusModelT, _ imagePath: String) throws -> [Float] {
    var embeddingBuffer = [Float](repeating: 0, count: 4096)
    var embeddingDim: Int = 0

    let result = embeddingBuffer.withUnsafeMutableBufferPointer { bufferPtr in
        cactus_image_embed(model, imagePath, bufferPtr.baseAddress, bufferPtr.count, &embeddingDim)
    }

    if result < 0 { throw _err("Image embedding failed") }
    return Array(embeddingBuffer.prefix(embeddingDim))
}

public func cactusAudioEmbed(_ model: CactusModelT, _ audioPath: String) throws -> [Float] {
    var embeddingBuffer = [Float](repeating: 0, count: 4096)
    var embeddingDim: Int = 0

    let result = embeddingBuffer.withUnsafeMutableBufferPointer { bufferPtr in
        cactus_audio_embed(model, audioPath, bufferPtr.baseAddress, bufferPtr.count, &embeddingDim)
    }

    if result < 0 { throw _err("Audio embedding failed") }
    return Array(embeddingBuffer.prefix(embeddingDim))
}

public func cactusVad(_ model: CactusModelT, _ audioPath: String?, _ optionsJson: String?, _ pcmData: Data?) throws -> String {
    var buffer = [CChar](repeating: 0, count: _defaultBufferSize)

    let result: Int32
    if let pcmData = pcmData {
        result = pcmData.withUnsafeBytes { pcmPtr in
            buffer.withUnsafeMutableBufferPointer { bufferPtr in
                cactus_vad(
                    model, audioPath,
                    bufferPtr.baseAddress, bufferPtr.count,
                    optionsJson,
                    pcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), pcmData.count
                )
            }
        }
    } else {
        result = buffer.withUnsafeMutableBufferPointer { bufferPtr in
            cactus_vad(model, audioPath, bufferPtr.baseAddress, bufferPtr.count, optionsJson, nil, 0)
        }
    }

    if result < 0 { throw _err("VAD failed") }
    return String(cString: buffer)
}

public func cactusDiarize(_ model: CactusModelT, _ audioPath: String?, _ optionsJson: String?, _ pcmData: Data?) throws -> String {
    var buffer = [CChar](repeating: 0, count: 1 << 20)

    let result: Int32
    if let pcmData = pcmData {
        result = pcmData.withUnsafeBytes { pcmPtr in
            buffer.withUnsafeMutableBufferPointer { bufferPtr in
                cactus_diarize(
                    model, audioPath,
                    bufferPtr.baseAddress, bufferPtr.count, optionsJson,
                    pcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), pcmData.count
                )
            }
        }
    } else {
        result = buffer.withUnsafeMutableBufferPointer { bufferPtr in
            cactus_diarize(model, audioPath, bufferPtr.baseAddress, bufferPtr.count, optionsJson, nil, 0)
        }
    }

    if result < 0 { throw _err("Diarize failed") }
    return String(cString: buffer)
}

public func cactusEmbedSpeaker(_ model: CactusModelT, _ audioPath: String?, _ optionsJson: String?, _ pcmData: Data?, _ maskWeights: [Float]? = nil) throws -> String {
    var buffer = [CChar](repeating: 0, count: _defaultBufferSize)

    let result: Int32
    if let pcmData = pcmData {
        result = pcmData.withUnsafeBytes { pcmPtr in
            buffer.withUnsafeMutableBufferPointer { bufferPtr in
                if let maskWeights = maskWeights {
                    return maskWeights.withUnsafeBufferPointer { maskPtr in
                        cactus_embed_speaker(
                            model, audioPath,
                            bufferPtr.baseAddress, bufferPtr.count, optionsJson,
                            pcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), pcmData.count,
                            maskPtr.baseAddress, maskWeights.count
                        )
                    }
                } else {
                    return cactus_embed_speaker(
                        model, audioPath,
                        bufferPtr.baseAddress, bufferPtr.count, optionsJson,
                        pcmPtr.baseAddress?.assumingMemoryBound(to: UInt8.self), pcmData.count,
                        nil, 0
                    )
                }
            }
        }
    } else {
        result = buffer.withUnsafeMutableBufferPointer { bufferPtr in
            if let maskWeights = maskWeights {
                return maskWeights.withUnsafeBufferPointer { maskPtr in
                    cactus_embed_speaker(model, audioPath, bufferPtr.baseAddress, bufferPtr.count, optionsJson, nil, 0, maskPtr.baseAddress, maskWeights.count)
                }
            } else {
                return cactus_embed_speaker(model, audioPath, bufferPtr.baseAddress, bufferPtr.count, optionsJson, nil, 0, nil, 0)
            }
        }
    }

    if result < 0 { throw _err("EmbedSpeaker failed") }
    return String(cString: buffer)
}

public func cactusRagQuery(_ model: CactusModelT, _ query: String, _ topK: Int) throws -> String {
    var buffer = [CChar](repeating: 0, count: _defaultBufferSize)

    let result = buffer.withUnsafeMutableBufferPointer { bufferPtr in
        cactus_rag_query(model, query, bufferPtr.baseAddress, bufferPtr.count, topK)
    }

    if result < 0 { throw _err("RAG query failed") }
    return String(cString: buffer)
}

// MARK: - Index

public func cactusIndexInit(_ indexDir: String, _ embeddingDim: Int) throws -> CactusIndexT {
    guard let h = cactus_index_init(indexDir, embeddingDim) else {
        throw _err("Failed to initialize index")
    }
    return h
}

public func cactusIndexDestroy(_ index: CactusIndexT) {
    cactus_index_destroy(index)
}

public func cactusIndexAdd(_ index: CactusIndexT, _ ids: [Int32], _ documents: [String], _ embeddings: [[Float]], _ metadatas: [String]?) throws {
    let count = ids.count
    let embeddingDim = embeddings[0].count

    var idArray = ids
    var docPtrs = documents.map { strdup($0) }
    var metaPtrs: [UnsafeMutablePointer<CChar>?]? = metadatas?.map { strdup($0) }
    var embPtrs = embeddings.map { emb -> UnsafePointer<Float>? in
        let ptr = UnsafeMutablePointer<Float>.allocate(capacity: emb.count)
        ptr.initialize(from: emb, count: emb.count)
        return UnsafePointer(ptr)
    }

    let result = idArray.withUnsafeMutableBufferPointer { idPtr in
        docPtrs.withUnsafeMutableBufferPointer { docPtr in
            embPtrs.withUnsafeMutableBufferPointer { embPtr in
                if let metaPtrs = metaPtrs {
                    var metaPtrsCopy = metaPtrs
                    return metaPtrsCopy.withUnsafeMutableBufferPointer { metaPtr in
                        cactus_index_add(
                            index,
                            idPtr.baseAddress,
                            unsafeBitCast(docPtr.baseAddress, to: UnsafeMutablePointer<UnsafePointer<CChar>?>?.self),
                            unsafeBitCast(metaPtr.baseAddress, to: UnsafeMutablePointer<UnsafePointer<CChar>?>?.self),
                            embPtr.baseAddress,
                            count, embeddingDim
                        )
                    }
                } else {
                    return cactus_index_add(
                        index,
                        idPtr.baseAddress,
                        unsafeBitCast(docPtr.baseAddress, to: UnsafeMutablePointer<UnsafePointer<CChar>?>?.self),
                        nil,
                        embPtr.baseAddress,
                        count, embeddingDim
                    )
                }
            }
        }
    }

    docPtrs.forEach { free($0) }
    metaPtrs?.forEach { free($0) }
    embPtrs.forEach { if let p = $0 { UnsafeMutablePointer(mutating: p).deallocate() } }

    if result < 0 { throw _err("Failed to add documents to index") }
}

public func cactusIndexDelete(_ index: CactusIndexT, _ ids: [Int32]) throws {
    var idArray = ids
    let result = idArray.withUnsafeMutableBufferPointer { idPtr in
        cactus_index_delete(index, idPtr.baseAddress, ids.count)
    }

    if result < 0 { throw _err("Failed to delete documents from index") }
}

public func cactusIndexGet(_ index: CactusIndexT, _ ids: [Int32]) throws -> String {
    let count = ids.count
    var idArray = ids

    let docBufSize = 4096
    let embBufSize = 4096

    let docRaw = (0..<count).map { _ -> UnsafeMutablePointer<CChar> in
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: docBufSize)
        p.initialize(repeating: 0, count: docBufSize)
        return p
    }
    let metaRaw = (0..<count).map { _ -> UnsafeMutablePointer<CChar> in
        let p = UnsafeMutablePointer<CChar>.allocate(capacity: docBufSize)
        p.initialize(repeating: 0, count: docBufSize)
        return p
    }
    let embRaw = (0..<count).map { _ -> UnsafeMutablePointer<Float> in
        let p = UnsafeMutablePointer<Float>.allocate(capacity: embBufSize)
        p.initialize(repeating: 0, count: embBufSize)
        return p
    }
    defer {
        docRaw.forEach { $0.deallocate() }
        metaRaw.forEach { $0.deallocate() }
        embRaw.forEach { $0.deallocate() }
    }

    var docBuffers: [UnsafeMutablePointer<CChar>?] = docRaw.map { Optional($0) }
    var docBufferSizes = [Int](repeating: docBufSize, count: count)
    var metaBuffers: [UnsafeMutablePointer<CChar>?] = metaRaw.map { Optional($0) }
    var metaBufferSizes = [Int](repeating: docBufSize, count: count)
    var embBuffers: [UnsafeMutablePointer<Float>?] = embRaw.map { Optional($0) }
    var embBufferSizes = [Int](repeating: embBufSize, count: count)

    let result = idArray.withUnsafeMutableBufferPointer { idPtr in
        docBuffers.withUnsafeMutableBufferPointer { docPtr in
            docBufferSizes.withUnsafeMutableBufferPointer { docSzPtr in
                metaBuffers.withUnsafeMutableBufferPointer { metaPtr in
                    metaBufferSizes.withUnsafeMutableBufferPointer { metaSzPtr in
                        embBuffers.withUnsafeMutableBufferPointer { embPtr in
                            embBufferSizes.withUnsafeMutableBufferPointer { embSzPtr in
                                cactus_index_get(
                                    index,
                                    idPtr.baseAddress, count,
                                    unsafeBitCast(docPtr.baseAddress, to: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?.self),
                                    docSzPtr.baseAddress,
                                    unsafeBitCast(metaPtr.baseAddress, to: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?.self),
                                    metaSzPtr.baseAddress,
                                    unsafeBitCast(embPtr.baseAddress, to: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?.self),
                                    embSzPtr.baseAddress
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    if result < 0 { throw _err("Failed to get from index") }

    var sb = "{\"results\":["
    for i in 0..<count {
        if i > 0 { sb += "," }
        let doc = String(cString: docRaw[i])
        let metaStr = String(cString: metaRaw[i])
        sb += "{\"document\":\"\(doc)\""
        if !metaStr.isEmpty {
            sb += ",\"metadata\":\"\(metaStr)\""
        } else {
            sb += ",\"metadata\":null"
        }
        sb += ",\"embedding\":["
        let embDim = embBufferSizes[i]
        for j in 0..<embDim {
            if j > 0 { sb += "," }
            sb += "\(embRaw[i][j])"
        }
        sb += "]}"
    }
    sb += "]}"
    return sb
}

public func cactusIndexQuery(_ index: CactusIndexT, _ embedding: [Float], _ optionsJson: String?) throws -> String {
    let resultCapacity = 1000
    var embeddingCopy = embedding
    var idBuffer = [Int32](repeating: 0, count: resultCapacity)
    var scoreBuffer = [Float](repeating: 0, count: resultCapacity)
    var idBufferSize = resultCapacity
    var scoreBufferSize = resultCapacity

    let result: Int32
    if let optStr = optionsJson {
        result = embeddingCopy.withUnsafeMutableBufferPointer { embPtr in
            idBuffer.withUnsafeMutableBufferPointer { idPtr in
                scoreBuffer.withUnsafeMutableBufferPointer { scorePtr in
                    var embPtrPtr: UnsafePointer<Float>? = embPtr.baseAddress.map { UnsafePointer($0) }
                    var idPtrPtr: UnsafeMutablePointer<Int32>? = idPtr.baseAddress
                    var scorePtrPtr: UnsafeMutablePointer<Float>? = scorePtr.baseAddress
                    var optStrCopy = optStr
                    return withUnsafeMutablePointer(to: &embPtrPtr) { embPtrPtrPtr in
                        withUnsafeMutablePointer(to: &idPtrPtr) { idPtrPtrPtr in
                            withUnsafeMutablePointer(to: &scorePtrPtr) { scorePtrPtrPtr in
                                withUnsafeMutablePointer(to: &idBufferSize) { idSizePtr in
                                    withUnsafeMutablePointer(to: &scoreBufferSize) { scoreSizePtr in
                                        optStrCopy.withCString { optCStr in
                                            cactus_index_query(
                                                index,
                                                embPtrPtrPtr, 1, embedding.count, optCStr,
                                                idPtrPtrPtr, idSizePtr,
                                                scorePtrPtrPtr, scoreSizePtr
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    } else {
        result = embeddingCopy.withUnsafeMutableBufferPointer { embPtr in
            idBuffer.withUnsafeMutableBufferPointer { idPtr in
                scoreBuffer.withUnsafeMutableBufferPointer { scorePtr in
                    var embPtrPtr: UnsafePointer<Float>? = embPtr.baseAddress.map { UnsafePointer($0) }
                    var idPtrPtr: UnsafeMutablePointer<Int32>? = idPtr.baseAddress
                    var scorePtrPtr: UnsafeMutablePointer<Float>? = scorePtr.baseAddress
                    return withUnsafeMutablePointer(to: &embPtrPtr) { embPtrPtrPtr in
                        withUnsafeMutablePointer(to: &idPtrPtr) { idPtrPtrPtr in
                            withUnsafeMutablePointer(to: &scorePtrPtr) { scorePtrPtrPtr in
                                withUnsafeMutablePointer(to: &idBufferSize) { idSizePtr in
                                    withUnsafeMutablePointer(to: &scoreBufferSize) { scoreSizePtr in
                                        cactus_index_query(
                                            index,
                                            embPtrPtrPtr, 1, embedding.count, nil,
                                            idPtrPtrPtr, idSizePtr,
                                            scorePtrPtrPtr, scoreSizePtr
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    if result < 0 { throw _err("Index query failed") }

    var sb = "{\"results\":["
    for i in 0..<idBufferSize {
        if i > 0 { sb += "," }
        sb += "{\"id\":\(idBuffer[i]),\"score\":\(scoreBuffer[i])}"
    }
    sb += "]}"
    return sb
}

public func cactusIndexCompact(_ index: CactusIndexT) throws {
    let result = cactus_index_compact(index)
    if result < 0 { throw _err("Failed to compact index") }
}

// MARK: - Logging

public func cactusLogSetLevel(_ level: Int32) {
    cactus_log_set_level(level)
}

private var _logCallbackContext: ((Int32, String, String) -> Void)?

private func logCallbackBridge(level: Int32, component: UnsafePointer<CChar>?, message: UnsafePointer<CChar>?, userData: UnsafeMutableRawPointer?) {
    guard let component = component, let message = message else { return }
    _logCallbackContext?(level, String(cString: component), String(cString: message))
}

public func cactusLogSetCallback(_ callback: ((Int32, String, String) -> Void)?) {
    _logCallbackContext = callback
    if callback != nil {
        cactus_log_set_callback(logCallbackBridge, nil)
    } else {
        cactus_log_set_callback(nil, nil)
    }
}

// MARK: - Model download + initialization

public struct ModelDownloadConfiguration: Sendable {
    public var modelURL: URL
    public var expectedModelSizeBytes: Int64
    public var modelDirectoryName: String
    public var modelFileName: String

    public init(
        modelURL: URL,
        expectedModelSizeBytes: Int64,
        modelDirectoryName: String,
        modelFileName: String
    ) {
        self.modelURL = modelURL
        self.expectedModelSizeBytes = expectedModelSizeBytes
        self.modelDirectoryName = modelDirectoryName
        self.modelFileName = modelFileName
    }

    public static let live = ModelDownloadConfiguration(
        modelURL: URL(string: "https://huggingface.co/Cactus-Compute/gemma-4-E4B-it/resolve/main/weights/gemma-4-e4b-it-int4-apple.zip")!,
        expectedModelSizeBytes: 6_439_205_261,
        modelDirectoryName: "gemma-4-e4b-it",
        modelFileName: ".complete"
    )
}

public struct ModelDownloadRequest: Sendable {
    public let url: URL
    public let resumeData: Data?

    public init(url: URL, resumeData: Data?) {
        self.url = url
        self.resumeData = resumeData
    }
}

public protocol URLSessionDownloading: AnyObject {
    func download(
        request: ModelDownloadRequest,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL
}

public protocol StorageChecking: Sendable {
    func availableStorageBytes(for url: URL) throws -> Int64
}

public struct VolumeStorageChecker: StorageChecking {
    public init() {}

    public func availableStorageBytes(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ])

        if let importantCapacity = values.volumeAvailableCapacityForImportantUsage {
            return Int64(importantCapacity)
        }

        if let generalCapacity = values.volumeAvailableCapacity {
            return Int64(generalCapacity)
        }

        throw NSError(
            domain: "TacNet.ModelDownload",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Unable to read available storage capacity."]
        )
    }
}

public enum URLSessionDownloadClientError: Error {
    case interrupted(resumeData: Data?)
    case missingTemporaryFile
    case transport(NSError)
    case httpError(statusCode: Int)
}

public final class URLSessionDownloadClient: NSObject, URLSessionDownloading {
    private struct CallbackBundle {
        let progress: @Sendable (Int64, Int64) -> Void
        let completion: @Sendable (Result<URL, Error>) -> Void
    }

    private let lock = NSLock()
    private var callbacksByTaskID: [Int: CallbackBundle] = [:]
    private var downloadedLocationsByTaskID: [Int: URL] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 86400
        config.waitsForConnectivity = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    public func download(
        request: ModelDownloadRequest,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task: URLSessionDownloadTask
            if let resumeData = request.resumeData, !resumeData.isEmpty {
                task = session.downloadTask(withResumeData: resumeData)
            } else {
                var urlRequest = URLRequest(url: request.url)
                urlRequest.setValue("1", forHTTPHeaderField: "X-HF-No-Xet")
                task = session.downloadTask(with: urlRequest)
            }

            let bundle = CallbackBundle(
                progress: progress,
                completion: { result in
                    continuation.resume(with: result)
                }
            )

            lock.withLock {
                callbacksByTaskID[task.taskIdentifier] = bundle
            }

            task.resume()
        }
    }
}

extension URLSessionDownloadClient: URLSessionDownloadDelegate {
    public func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData _: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let callback = lock.withLock { callbacksByTaskID[downloadTask.taskIdentifier] }
        callback?.progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    public func urlSession(
        _: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Apple deletes the temp file when this method returns,
        // so move it to a stable location immediately.
        let stableURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TacNet_download_\(downloadTask.taskIdentifier).tmp")
        do {
            if FileManager.default.fileExists(atPath: stableURL.path) {
                try FileManager.default.removeItem(at: stableURL)
            }
            try FileManager.default.moveItem(at: location, to: stableURL)
            lock.withLock {
                downloadedLocationsByTaskID[downloadTask.taskIdentifier] = stableURL
            }
        } catch {
            lock.withLock {
                downloadedLocationsByTaskID[downloadTask.taskIdentifier] = nil
            }
        }
    }

    public func urlSession(_: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let callbackBundle: CallbackBundle? = lock.withLock {
            defer {
                callbacksByTaskID.removeValue(forKey: task.taskIdentifier)
            }
            return callbacksByTaskID[task.taskIdentifier]
        }

        guard let callbackBundle else { return }

        if let error {
            let nsError = error as NSError
            let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if resumeData != nil {
                callbackBundle.completion(.failure(URLSessionDownloadClientError.interrupted(resumeData: resumeData)))
            } else {
                callbackBundle.completion(.failure(URLSessionDownloadClientError.transport(nsError)))
            }
            return
        }

        let downloadedLocation = lock.withLock {
            defer {
                downloadedLocationsByTaskID.removeValue(forKey: task.taskIdentifier)
            }
            return downloadedLocationsByTaskID[task.taskIdentifier]
        }

        guard let downloadedLocation else {
            callbackBundle.completion(.failure(URLSessionDownloadClientError.missingTemporaryFile))
            return
        }

        if let httpResponse = task.response as? HTTPURLResponse,
           !(200..<300).contains(httpResponse.statusCode) {
            try? FileManager.default.removeItem(at: downloadedLocation)
            callbackBundle.completion(.failure(URLSessionDownloadClientError.httpError(statusCode: httpResponse.statusCode)))
            return
        }

        callbackBundle.completion(.success(downloadedLocation))
    }
}

public enum ModelDownloadServiceError: Error, Equatable {
    case insufficientStorage(requiredBytes: Int64, availableBytes: Int64)
    case interrupted(canResume: Bool)
    case network(underlyingDescription: String)
}

public actor ModelDownloadService {
    public typealias ProgressHandler = @Sendable (Double) -> Void

    public static let live = ModelDownloadService()

    private let configuration: ModelDownloadConfiguration
    private let downloader: URLSessionDownloading
    private let storageChecker: StorageChecking
    private let fileManager: FileManager
    private let userDefaults: UserDefaults
    private let applicationSupportDirectory: URL
    private let completionKey: String
    private let resumeDataKey: String

    public init(
        configuration: ModelDownloadConfiguration = .live,
        downloader: URLSessionDownloading = URLSessionDownloadClient(),
        storageChecker: StorageChecking = VolumeStorageChecker(),
        fileManager: FileManager = .default,
        userDefaults: UserDefaults = .standard,
        applicationSupportDirectory: URL? = nil,
        persistenceKeyPrefix: String = "TacNet.ModelDownload"
    ) {
        self.configuration = configuration
        self.downloader = downloader
        self.storageChecker = storageChecker
        self.fileManager = fileManager
        self.userDefaults = userDefaults
        self.applicationSupportDirectory = applicationSupportDirectory
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        completionKey = "\(persistenceKeyPrefix).complete"
        resumeDataKey = "\(persistenceKeyPrefix).resumeData"
    }

    public func canUseTacticalFeatures() -> Bool {
        synchronizeCompletionState()
    }

    public func downloadedModelDirectoryPath() -> String? {
        synchronizeCompletionState() ? modelDirectoryURL.path : nil
    }

    private static let maxRetryAttempts = 5
    private static let retryBaseDelay: UInt64 = 2_000_000_000 // 2 seconds in nanoseconds

    @discardableResult
    public func ensureModelAvailable(progressHandler: ProgressHandler? = nil) async throws -> URL {
        if synchronizeCompletionState() {
            NSLog("[ModelDownload] Model already present at %@, skipping download", modelDirectoryURL.path)
            progressHandler?(1.0)
            return modelDirectoryURL
        }

        // Diagnostic: log what's currently in applicationSupportDirectory so we
        // can confirm whether orphaned model files are present before migrating.
        let appSupportContents = (try? fileManager.contentsOfDirectory(atPath: applicationSupportDirectory.path)) ?? []
        let weightsInRoot = appSupportContents.filter { ($0 as NSString).pathExtension == "weights" }.count
        NSLog("[ModelDownload] Diagnostic — app support root contains %d total items, %d .weights files", appSupportContents.count, weightsInRoot)

        // Recovery: a previous extraction may have landed files directly in
        // applicationSupportDirectory instead of modelDirectoryURL (wrong destination
        // bug). If we find >500 .weights files there, migrate them in-place rather
        // than re-downloading 6.4 GB.
        if recoverMisplacedExtraction() {
            NSLog("[ModelDownload] Recovery migration succeeded — skipping download")
            progressHandler?(1.0)
            return modelDirectoryURL
        }

        let availableStorage = try storageChecker.availableStorageBytes(for: applicationSupportDirectory)
        NSLog("[ModelDownload] Storage check — available: %lld bytes, required: %lld bytes", availableStorage, configuration.expectedModelSizeBytes)
        guard availableStorage >= configuration.expectedModelSizeBytes else {
            throw ModelDownloadServiceError.insufficientStorage(
                requiredBytes: configuration.expectedModelSizeBytes,
                availableBytes: availableStorage
            )
        }

        try fileManager.createDirectory(at: modelDirectoryURL, withIntermediateDirectories: true)

        let progressReporter = ProgressReporter(progressHandler: progressHandler)
        progressReporter.report(0)

        var lastNonRecoverableError: ModelDownloadServiceError?

        retryLoop: for attempt in 0..<Self.maxRetryAttempts {
            if attempt > 0 {
                let delay = Self.retryBaseDelay * UInt64(min(attempt, 4))
                NSLog("[ModelDownload] Retry attempt %d, waiting %llu ns", attempt, delay)
                try await Task.sleep(nanoseconds: delay)
            }

            NSLog("[ModelDownload] Attempt %d — starting download from %@", attempt, configuration.modelURL.absoluteString)

            let request = ModelDownloadRequest(
                url: configuration.modelURL,
                resumeData: userDefaults.data(forKey: resumeDataKey)
            )

            do {
                let temporaryLocation = try await downloader.download(
                    request: request,
                    progress: { written, total in
                        progressReporter.report(bytesWritten: written, totalBytes: total)
                    }
                )

                NSLog("[ModelDownload] Download finished — temporary file at %@", temporaryLocation.path)

                // Validate the zip size before doing anything else.
                let zipAttributes = try fileManager.attributesOfItem(atPath: temporaryLocation.path)
                let zipSize = (zipAttributes[.size] as? Int64) ?? 0
                let minimumExpectedSize = configuration.expectedModelSizeBytes / 4
                NSLog("[ModelDownload] Zip size: %lld bytes (minimum expected: %lld bytes)", zipSize, minimumExpectedSize)
                guard zipSize >= minimumExpectedSize else {
                    try? fileManager.removeItem(at: temporaryLocation)
                    lastNonRecoverableError = .network(
                        underlyingDescription: "Downloaded file is too small (\(zipSize) bytes). Expected ~\(configuration.expectedModelSizeBytes) bytes. The model URL may be inaccessible or require authentication."
                    )
                    break retryLoop
                }

                // Remove any previously partially-extracted model directory so
                // the extraction always starts from a clean slate.
                if fileManager.fileExists(atPath: modelDirectoryURL.path) {
                    NSLog("[ModelDownload] Removing previous partial extraction at %@", modelDirectoryURL.path)
                    try fileManager.removeItem(at: modelDirectoryURL)
                }

                NSLog("[ModelDownload] Extracting zip to %@", modelDirectoryURL.path)
                // The zip contains 2088 .weights files at its root (no top-level
                // subdirectory), so extract directly into modelDirectoryURL so
                // all files land in the right place for cactusInit.
                try fileManager.unzipItem(at: temporaryLocation, to: modelDirectoryURL)
                try? fileManager.removeItem(at: temporaryLocation)
                NSLog("[ModelDownload] Extraction complete")

                let extractedCount = (try? fileManager.contentsOfDirectory(atPath: modelDirectoryURL.path))?.count ?? 0
                NSLog("[ModelDownload] Extracted %d files into %@", extractedCount, modelDirectoryURL.path)

                guard fileManager.fileExists(atPath: modelDirectoryURL.path) else {
                    lastNonRecoverableError = .network(
                        underlyingDescription: "Zip extraction completed but the model directory was not found at the expected path. The zip may have a different internal structure."
                    )
                    break retryLoop
                }

                // Write the sentinel so future launches can detect a complete download.
                fileManager.createFile(atPath: modelFileURL.path, contents: nil, attributes: nil)
                userDefaults.removeObject(forKey: resumeDataKey)
                userDefaults.set(true, forKey: completionKey)
                NSLog("[ModelDownload] Sentinel written at %@, download complete", modelFileURL.path)

                progressReporter.finish()
                return modelDirectoryURL
            } catch let error as URLSessionDownloadClientError {
                switch error {
                case let .interrupted(resumeData):
                    if let resumeData, !resumeData.isEmpty {
                        userDefaults.set(resumeData, forKey: resumeDataKey)
                    }
                    // Auto-retry interrupted downloads
                    continue
                case let .transport(transportError):
                    let isTransient = [
                        NSURLErrorTimedOut,
                        NSURLErrorNetworkConnectionLost,
                        NSURLErrorNotConnectedToInternet,
                        NSURLErrorCannotConnectToHost
                    ].contains(transportError.code)
                    if isTransient {
                        continue
                    }
                    lastNonRecoverableError = .network(
                        underlyingDescription: "\(transportError.domain)(\(transportError.code)): \(transportError.localizedDescription)"
                    )
                    break retryLoop
                case let .httpError(statusCode):
                    NSLog("[ModelDownload] HTTP error %d from server", statusCode)
                    lastNonRecoverableError = .network(
                        underlyingDescription: "Server returned HTTP \(statusCode). Check that the model URL is correct and publicly accessible."
                    )
                    break retryLoop
                case .missingTemporaryFile:
                    NSLog("[ModelDownload] Error: download completed but temp file was missing")
                    lastNonRecoverableError = .network(underlyingDescription: "Download completed without a temporary file.")
                    break retryLoop
                }
            } catch {
                NSLog("[ModelDownload] Unexpected error on attempt %d: %@", attempt, error.localizedDescription)
                lastNonRecoverableError = .network(underlyingDescription: error.localizedDescription)
                break retryLoop
            }
        }

        if let lastNonRecoverableError {
            NSLog("[ModelDownload] Giving up after all attempts — final error: %@", String(describing: lastNonRecoverableError))
            throw lastNonRecoverableError
        }

        let hasResumeData = userDefaults.data(forKey: resumeDataKey)?.isEmpty == false
        throw ModelDownloadServiceError.interrupted(canResume: hasResumeData)
    }

    private var modelDirectoryURL: URL {
        applicationSupportDirectory.appendingPathComponent(configuration.modelDirectoryName, isDirectory: true)
    }

    private var modelFileURL: URL {
        modelDirectoryURL.appendingPathComponent(configuration.modelFileName, isDirectory: false)
    }

    /// Detects files extracted to the wrong location by a previous buggy run and
    /// moves them into `modelDirectoryURL` without re-downloading. Returns `true`
    /// if recovery succeeded and the model is ready to use.
    @discardableResult
    private func recoverMisplacedExtraction() -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: applicationSupportDirectory.path) else {
            return false
        }

        let modelExtensions: Set<String> = ["weights", "bias", "json", "txt", "jinja2", "mlpackage", "mlmodelc"]
        let orphans = contents.filter { name in
            modelExtensions.contains((name as NSString).pathExtension)
        }

        // Use .weights count as the fingerprint — the model has 2076 .weights files.
        // >500 in app support root is unambiguously a misplaced extraction.
        let weightsCount = orphans.filter { ($0 as NSString).pathExtension == "weights" }.count
        guard weightsCount > 500 else { return false }

        NSLog("[ModelDownload] Found %d orphaned model files in app support root — migrating (skips 6.4 GB re-download)", orphans.count)

        do {
            try fileManager.createDirectory(at: modelDirectoryURL, withIntermediateDirectories: true)
            var moved = 0
            for name in orphans {
                let src = applicationSupportDirectory.appendingPathComponent(name)
                let dst = modelDirectoryURL.appendingPathComponent(name)
                guard !fileManager.fileExists(atPath: dst.path) else { continue }
                try fileManager.moveItem(at: src, to: dst)
                moved += 1
            }
            NSLog("[ModelDownload] Migrated %d files to %@", moved, modelDirectoryURL.path)
            fileManager.createFile(atPath: modelFileURL.path, contents: nil, attributes: nil)
            userDefaults.set(true, forKey: completionKey)
            return true
        } catch {
            NSLog("[ModelDownload] Migration failed: %@", error.localizedDescription)
            return false
        }
    }

    private func synchronizeCompletionState() -> Bool {
        // Both the sentinel file AND the model directory must be present.
        // If either is missing the extraction was incomplete; clean up so
        // this launch triggers a fresh download automatically — no reinstall needed.
        guard fileManager.fileExists(atPath: modelFileURL.path),
              fileManager.fileExists(atPath: modelDirectoryURL.path) else {
            try? fileManager.removeItem(at: modelDirectoryURL)
            try? fileManager.removeItem(at: modelFileURL)
            userDefaults.set(false, forKey: completionKey)
            userDefaults.removeObject(forKey: resumeDataKey)
            return false
        }

        userDefaults.set(true, forKey: completionKey)
        return true
    }
}

public enum CactusModelInitializationError: Error, Equatable {
    case downloadIncomplete
    case initializationFailed(String)
}

public actor CactusModelInitializationService {
    public typealias InitFunction = (String, String?, Bool) throws -> CactusModelT
    public typealias DestroyFunction = (CactusModelT) -> Void

    private let downloadService: ModelDownloadService
    private let initFunction: InitFunction
    private let destroyFunction: DestroyFunction
    private var loadedModelHandle: CactusModelT?

    public init(
        downloadService: ModelDownloadService = .live,
        initFunction: @escaping InitFunction = cactusInit,
        destroyFunction: @escaping DestroyFunction = cactusDestroy
    ) {
        self.downloadService = downloadService
        self.initFunction = initFunction
        self.destroyFunction = destroyFunction
    }

    public func initializeModel() async throws -> CactusModelT {
        if let loadedModelHandle {
            return loadedModelHandle
        }

        guard await downloadService.canUseTacticalFeatures(),
              let modelDirectoryPath = await downloadService.downloadedModelDirectoryPath()
        else {
            throw CactusModelInitializationError.downloadIncomplete
        }

        return try initialize(using: modelDirectoryPath)
    }

    public func initializeModelAfterEnsuringDownload(
        progressHandler: ModelDownloadService.ProgressHandler? = nil
    ) async throws -> CactusModelT {
        if let loadedModelHandle {
            return loadedModelHandle
        }

        let modelDirectory = try await downloadService.ensureModelAvailable(progressHandler: progressHandler)
        return try initialize(using: modelDirectory.path)
    }

    public func destroyModelIfLoaded() {
        guard let loadedModelHandle else { return }
        destroyFunction(loadedModelHandle)
        self.loadedModelHandle = nil
    }

    private func initialize(using modelPath: String) throws -> CactusModelT {
        do {
            let handle = try initFunction(modelPath, nil, false)
            loadedModelHandle = handle
            return handle
        } catch {
            throw CactusModelInitializationError.initializationFailed(error.localizedDescription)
        }
    }
}

private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let progressHandler: (@Sendable (Double) -> Void)?
    private var lastEmittedProgress: Double = 0
    private var nextMilestoneProgress: Double = 0.1

    init(progressHandler: (@Sendable (Double) -> Void)?) {
        self.progressHandler = progressHandler
    }

    func report(bytesWritten: Int64, totalBytes: Int64) {
        guard totalBytes > 0 else { return }
        report(Double(bytesWritten) / Double(totalBytes))
    }

    func report(_ progress: Double) {
        lock.withLock {
            let clamped = min(max(progress, 0), 1)
            emitMilestones(upTo: min(clamped, 0.9))

            if clamped < 1 {
                emitIfNeeded(clamped)
            }
        }
    }

    func finish() {
        lock.withLock {
            emitMilestones(upTo: 0.9)
            emitIfNeeded(1)
        }
    }

    private func emitMilestones(upTo limit: Double) {
        while nextMilestoneProgress <= limit + 0.000_000_1 {
            emitIfNeeded(nextMilestoneProgress)
            nextMilestoneProgress += 0.1
        }
    }

    private func emitIfNeeded(_ progress: Double) {
        guard progress > lastEmittedProgress + 0.000_000_1 else { return }
        lastEmittedProgress = progress
        progressHandler?(progress)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
