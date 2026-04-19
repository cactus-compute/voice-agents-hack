import { useCallback, useEffect, useRef } from 'react';
import * as Speech from 'expo-speech';
import { Platform } from 'react-native';

/**
 * Native system TTS — instant, free, no extra model download.
 *
 * We deliberately pick a slightly slower-than-default rate and a lower
 * pitch to make Aurora sound more grounded. The default iOS / Android
 * voices land in the right register without needing a custom voice file.
 *
 * The `onDone` callback fires whether the speech finished naturally or
 * was interrupted by `stop()`, so callers can rely on it to flip the
 * conversation phase back to `idle`.
 */

export interface SpeakOptions {
  onStart?: () => void;
  onDone?: () => void;
  onError?: (e: Error) => void;
}

export function useTTS() {
  const isSpeakingRef = useRef(false);

  useEffect(() => {
    return () => {
      Speech.stop().catch(() => undefined);
    };
  }, []);

  const speak = useCallback((text: string, opts: SpeakOptions = {}) => {
    if (!text.trim()) {
      opts.onDone?.();
      return;
    }
    isSpeakingRef.current = true;
    Speech.stop().finally(() => {
      Speech.speak(text, {
        language: 'en-US',
        rate: Platform.OS === 'ios' ? 0.48 : 0.92,
        pitch: Platform.OS === 'ios' ? 1.0 : 0.95,
        onStart: () => opts.onStart?.(),
        onDone: () => {
          isSpeakingRef.current = false;
          opts.onDone?.();
        },
        onStopped: () => {
          isSpeakingRef.current = false;
          opts.onDone?.();
        },
        onError: (e) => {
          isSpeakingRef.current = false;
          opts.onError?.(e instanceof Error ? e : new Error(String(e)));
        },
      });
    });
  }, []);

  const stop = useCallback(async () => {
    isSpeakingRef.current = false;
    await Speech.stop().catch(() => undefined);
  }, []);

  return { speak, stop, isSpeakingRef };
}
