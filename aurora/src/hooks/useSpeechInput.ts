import { useCallback, useEffect, useRef, useState } from 'react';
import {
  ExpoSpeechRecognitionModule,
  useSpeechRecognitionEvent,
} from 'expo-speech-recognition';

/**
 * Hold-to-talk speech input using the device's native recognizer.
 *
 * iOS uses the on-device Speech framework; Android uses the system
 * SpeechRecognizer. Both run locally on modern devices, so the
 * "nothing leaves the phone" promise holds — no network STT.
 *
 * The hook surfaces the same shape the rest of the app expects:
 *   start()   — open the mic, start recognizing
 *   stop()    — stop and return the final transcript
 *   cancel()  — abort without returning
 *   meterDb   — rough level for the breathing orb
 */

export interface SpeechInput {
  hasPermission: boolean | null;
  isListening: boolean;
  partialText: string;
  meterDb: number;
  requestPermission: () => Promise<boolean>;
  start: () => Promise<void>;
  stop: () => Promise<string | null>;
  cancel: () => Promise<void>;
}

export function useSpeechInput(): SpeechInput {
  const [hasPermission, setHasPermission] = useState<boolean | null>(null);
  const [isListening, setIsListening] = useState(false);
  const [partialText, setPartialText] = useState('');
  const [meterDb, setMeterDb] = useState(-160);

  const finalTextRef = useRef('');
  const resolveStopRef = useRef<((t: string | null) => void) | null>(null);

  useEffect(() => {
    ExpoSpeechRecognitionModule.getPermissionsAsync()
      .then((res) => setHasPermission(res.granted))
      .catch(() => setHasPermission(false));
  }, []);

  useSpeechRecognitionEvent('result', (event) => {
    const t = event.results?.[0]?.transcript ?? '';
    setPartialText(t);
    if (event.isFinal) finalTextRef.current = t;
  });

  useSpeechRecognitionEvent('volumechange', (event) => {
    if (typeof event.value === 'number') {
      // Native value is roughly -2..10; map to dBFS-ish range for the orb.
      const db = -60 + event.value * 6;
      setMeterDb(db);
    }
  });

  useSpeechRecognitionEvent('end', () => {
    setIsListening(false);
    setMeterDb(-160);
    if (resolveStopRef.current) {
      const text = finalTextRef.current.trim() || partialText.trim();
      resolveStopRef.current(text || null);
      resolveStopRef.current = null;
      setPartialText('');
      finalTextRef.current = '';
    }
  });

  useSpeechRecognitionEvent('error', () => {
    setIsListening(false);
    setMeterDb(-160);
    if (resolveStopRef.current) {
      resolveStopRef.current(null);
      resolveStopRef.current = null;
    }
  });

  const requestPermission = useCallback(async () => {
    const res = await ExpoSpeechRecognitionModule.requestPermissionsAsync();
    setHasPermission(res.granted);
    return res.granted;
  }, []);

  const start = useCallback(async () => {
    if (isListening) return;
    if (hasPermission === false) {
      const ok = await requestPermission();
      if (!ok) throw new Error('Microphone / speech permission denied');
    }
    finalTextRef.current = '';
    setPartialText('');
    setIsListening(true);
    ExpoSpeechRecognitionModule.start({
      lang: 'en-US',
      interimResults: true,
      continuous: false,
      requiresOnDeviceRecognition: true,
      volumeChangeEventOptions: { enabled: true, intervalMillis: 100 },
    });
  }, [hasPermission, isListening, requestPermission]);

  const stop = useCallback((): Promise<string | null> => {
    if (!isListening) return Promise.resolve(null);
    return new Promise((resolve) => {
      resolveStopRef.current = resolve;
      ExpoSpeechRecognitionModule.stop();
    });
  }, [isListening]);

  const cancel = useCallback(async () => {
    resolveStopRef.current = null;
    setPartialText('');
    finalTextRef.current = '';
    setIsListening(false);
    setMeterDb(-160);
    try {
      ExpoSpeechRecognitionModule.abort();
    } catch {
      /* swallow */
    }
  }, []);

  return {
    hasPermission,
    isListening,
    partialText,
    meterDb,
    requestPermission,
    start,
    stop,
    cancel,
  };
}
