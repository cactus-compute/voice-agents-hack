import React, { useEffect, useMemo, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { activateKeepAwakeAsync, deactivateKeepAwake } from 'expo-keep-awake';

import { AuroraBackground } from '@/components/AuroraBackground';
import { BreathingOrb } from '@/components/BreathingOrb';
import { DisclaimerModal } from '@/components/DisclaimerModal';
import { DownloadProgress } from '@/components/DownloadProgress';
import { Header } from '@/components/Header';
import { MicButton } from '@/components/MicButton';
import { TranscriptCard } from '@/components/TranscriptCard';

import { useTherapist } from '@/hooks/useTherapist';
import { pickOpening } from '@/constants/systemPrompt';
import { palette } from '@/theme/colors';
import { spacing } from '@/theme/spacing';
import { type } from '@/theme/typography';

export function ConversationScreen() {
  const therapist = useTherapist();
  const { state, speech, cactus, beginListening, endListening, reset } = therapist;
  const [crisisOpen, setCrisisOpen] = useState(false);
  const [opening] = useState(pickOpening);

  useEffect(() => {
    activateKeepAwakeAsync('aurora-session').catch(() => undefined);
    return () => {
      deactivateKeepAwake('aurora-session');
    };
  }, []);

  useEffect(() => {
    if (state.crisisDetected) setCrisisOpen(true);
  }, [state.crisisDetected]);

  const lastUser = useMemo(
    () => [...state.messages].reverse().find((m) => m.role === 'user'),
    [state.messages]
  );
  const lastAssistant = useMemo(
    () => [...state.messages].reverse().find((m) => m.role === 'assistant'),
    [state.messages]
  );

  const isModelReady = cactus.isDownloaded === true;
  const subtitle = subtitleForPhase(state.phase, isModelReady, opening);

  const micDisabled =
    !isModelReady ||
    state.phase === 'thinking' ||
    state.phase === 'speaking';

  return (
    <AuroraBackground>
      <SafeAreaView style={styles.safe} edges={['top', 'bottom']}>
        <Header subtitle={subtitle} onReset={state.messages.length ? reset : undefined} />

        <View style={styles.orbWrap}>
          <BreathingOrb phase={state.phase} meterDb={speech.meterDb} size={260} />
        </View>

        <View style={styles.bottom}>
          {!isModelReady ? (
            <DownloadProgress progress={cactus.downloadProgress ?? 0} />
          ) : (
            <TranscriptCard
              phase={state.phase}
              lastUser={lastUser}
              lastAssistant={lastAssistant}
              partialAssistant={state.partialAssistantText}
            />
          )}

          {state.errorMessage ? (
            <Text style={styles.errorText}>{state.errorMessage}</Text>
          ) : null}

          <MicButton
            isActive={state.phase === 'listening'}
            disabled={micDisabled}
            onPressIn={beginListening}
            onPressOut={endListening}
          />
        </View>
      </SafeAreaView>

      <DisclaimerModal
        visible={crisisOpen}
        variant="crisis"
        onAccept={() => setCrisisOpen(false)}
        onDismissCrisis={() => setCrisisOpen(false)}
      />
    </AuroraBackground>
  );
}

function subtitleForPhase(
  phase: ReturnType<typeof useTherapist>['state']['phase'],
  ready: boolean,
  opening: string
): string {
  if (!ready) return 'Setting up on this device';
  switch (phase) {
    case 'listening':
      return 'Take your time';
    case 'thinking':
      return 'Sitting with that…';
    case 'speaking':
      return 'Speaking';
    case 'error':
      return 'Something went wrong';
    default:
      return opening;
  }
}

const styles = StyleSheet.create({
  safe: { flex: 1 },
  orbWrap: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  bottom: {
    paddingHorizontal: spacing.lg,
    paddingBottom: spacing.xl,
    gap: spacing.lg,
  },
  errorText: {
    ...type.meta,
    color: palette.danger,
    textAlign: 'center',
  },
});
