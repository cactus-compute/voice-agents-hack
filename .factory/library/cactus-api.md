# Cactus SDK Swift API Reference

## Integration

- XCFramework at: `/Users/yifuzuo/Desktop/yifu/startup/projects/hackathon/cactus/apple/cactus-ios.xcframework`
- Swift API file: `/Users/yifuzuo/Desktop/yifu/startup/projects/hackathon/cactus/apple/Cactus.swift`
- Module map: `import cactus` (via module.modulemap in the XCFramework)

## Types

```swift
public typealias CactusModelT = UnsafeMutableRawPointer
public typealias CactusStreamTranscribeT = UnsafeMutableRawPointer
```

## Lifecycle

```swift
// Init model - modelPath points to weight directory
let model = try cactusInit("/path/to/weights", nil, false)
// Parameters: modelPath: String, corpusDir: String?, cacheIndex: Bool

// Destroy model
cactusDestroy(model)

// Reset context
cactusReset(model)

// Stop current inference
cactusStop(model)
```

## Text Completion (for compaction/summarization)

```swift
let messages = #"[{"role":"system","content":"You are a tactical summarizer..."},{"role":"user","content":"Summarize: ..."}]"#
let options = #"{"max_tokens":100,"temperature":0.0}"#

// Non-streaming
let resultJson = try cactusComplete(model, messages, options, nil, nil)

// Streaming
let resultJson = try cactusComplete(model, messages, options, nil) { token, tokenId in
    print(token, terminator: "")
}

// With audio input (PCM data)
let pcmData: Data = ... // 16kHz mono 16-bit PCM
let resultJson = try cactusComplete(model, messages, options, nil, nil, pcmData)
```

Response JSON: `{"success":true, "response":"...", "time_to_first_token_ms":..., "decode_tps":...}`

## Transcription (STT)

```swift
// From file
let resultJson = try cactusTranscribe(model, "/path/to/audio.wav", nil, nil, nil, nil)

// From PCM buffer (16kHz mono 16-bit)
let pcmData: Data = ...
let resultJson = try cactusTranscribe(model, nil, nil, nil, nil, pcmData)

// With token callback
let resultJson = try cactusTranscribe(model, nil, nil, nil, { token, tokenId in
    print(token, terminator: "")
}, pcmData)
```

## Streaming Transcription (real-time)

```swift
let stream = try cactusStreamTranscribeStart(model, nil)
let partialJson = try cactusStreamTranscribeProcess(stream, audioChunkData)
let finalJson = try cactusStreamTranscribeStop(stream)
```

## Key Options

```json
{
  "max_tokens": 100,
  "temperature": 0.0,
  "top_p": 0.95,
  "min_p": 0.15,
  "repetition_penalty": 1.1,
  "stop_sequences": ["\n"],
  "custom_vocabulary": ["tactical", "medevac", "extraction"]
}
```

## Audio Format

All audio input must be: **16-bit signed integer PCM, 16000 Hz sample rate, mono (single channel)**.

## Error Handling

All functions throw `NSError(domain: "cactus", code: -1)` on failure. Use `cactusGetLastError()` for detailed error description.

## Model Weights

- Path: `/opt/homebrew/opt/cactus/libexec/weights/gemma-4-e4b-it/`
- Size: 6.7 GB (INT4 quantized)
- For app: download from Cactus-Compute HuggingFace on first launch
