import { useCallback, useEffect, useReducer, useRef } from 'react';
import { useCactusLM } from 'cactus-react-native';

import { conversationReducer, initialState } from '@/state/conversationReducer';
import type { Message } from '@/state/types';
import { SYSTEM_PROMPT } from '@/constants/systemPrompt';
import { detectCrisis } from '@/constants/safety';
import { useSpeechInput } from './useSpeechInput';
import { useTTS } from './useTTS';

/**
 * The `useTherapist` hook is the single seam between the UI and the
 * on-device model. The screen layer never touches Cactus directly;
 * everything goes through the verbs returned here:
 *
 *   beginListening() — open the mic, start native speech recognition
 *   endListening()   — stop recognizing, send transcript to model, speak reply
 *   cancel()         — abort current turn (recording or playback)
 *   reset()          — wipe conversation, start fresh
 *
 * Pipeline: device-native STT → Gemma (functiongemma-270m-it) → expo-speech TTS.
 * Both STT and the LLM run on-device, so nothing leaves the phone.
 */

const MODEL_ID = 'google/functiongemma-270m-it';

const GENERATION_OPTIONS = {
  temperature: 0.7,
  topP: 0.9,
  maxTokens: 180,
};

function toCactusMessages(history: Message[]) {
  return history.map((m) => ({
    role: m.role,
    content: m.content,
  }));
}

export function useTherapist() {
  const [state, dispatch] = useReducer(conversationReducer, initialState);
  const speech = useSpeechInput();
  const tts = useTTS();

  const cactus = useCactusLM({
    model: MODEL_ID,
  });

  const inFlightRef = useRef(false);

  useEffect(() => {
    if (!cactus.isDownloaded && !cactus.isDownloading) {
      cactus.download().catch(() => {
        dispatch({ type: 'ERROR', message: 'Could not start model download' });
      });
    }
  }, [cactus]);

  const beginListening = useCallback(async () => {
    if (inFlightRef.current) return;
    try {
      await tts.stop();
      await speech.start();
      dispatch({ type: 'START_LISTENING' });
    } catch (e) {
      dispatch({
        type: 'ERROR',
        message: e instanceof Error ? e.message : 'Could not start listening',
      });
    }
  }, [speech, tts]);

  const cancel = useCallback(async () => {
    inFlightRef.current = false;
    await speech.cancel();
    await tts.stop();
    dispatch({ type: 'CANCEL_LISTENING' });
  }, [speech, tts]);

  const endListening = useCallback(async () => {
    if (state.phase !== 'listening') return;
    const transcript = await speech.stop();
    if (!transcript) {
      dispatch({ type: 'CANCEL_LISTENING' });
      return;
    }

    inFlightRef.current = true;
    dispatch({ type: 'USER_TURN', userText: transcript });

    const userMessage = {
      role: 'user' as const,
      content: transcript,
    };

    const messages = [
      { role: 'system' as const, content: SYSTEM_PROMPT },
      ...toCactusMessages(state.messages),
      userMessage,
    ];

    try {
      await cactus.complete({
        messages,
        options: GENERATION_OPTIONS,
        onToken: (token: string) => {
          dispatch({ type: 'ASSISTANT_PARTIAL', chunk: token });
        },
      });
    } catch (e) {
      inFlightRef.current = false;
      dispatch({
        type: 'ERROR',
        message: e instanceof Error ? e.message : 'Model failed to respond',
      });
      return;
    }

    dispatch({ type: 'ASSISTANT_DONE' });
  }, [cactus, speech, state.messages, state.phase]);

  // When a new assistant message lands, speak it and run the safety check.
  const lastSpokenIdRef = useRef<string | null>(null);
  useEffect(() => {
    const last = state.messages[state.messages.length - 1];
    if (!last || last.role !== 'assistant') return;
    if (lastSpokenIdRef.current === last.id) return;
    lastSpokenIdRef.current = last.id;

    if (detectCrisis(last.content)) {
      dispatch({ type: 'CRISIS_FLAG' });
    }

    tts.speak(last.content, {
      onStart: () => dispatch({ type: 'SPEAK_START' }),
      onDone: () => {
        inFlightRef.current = false;
        dispatch({ type: 'SPEAK_END' });
      },
      onError: () => {
        inFlightRef.current = false;
        dispatch({ type: 'SPEAK_END' });
      },
    });
  }, [state.messages, tts]);

  // Watch for crisis cues in the user transcript too.
  useEffect(() => {
    if (state.crisisDetected) return;
    const lastUser = [...state.messages].reverse().find((m) => m.role === 'user');
    if (lastUser && detectCrisis(lastUser.content)) {
      dispatch({ type: 'CRISIS_FLAG' });
    }
  }, [state.messages, state.crisisDetected]);

  const reset = useCallback(async () => {
    await cancel();
    lastSpokenIdRef.current = null;
    dispatch({ type: 'RESET' });
  }, [cancel]);

  return {
    state,
    speech,
    cactus,
    beginListening,
    endListening,
    cancel,
    reset,
  };
}
