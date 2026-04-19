import 'react-native-reanimated';
import React, { useState } from 'react';
import { StatusBar } from 'expo-status-bar';
import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { SafeAreaProvider } from 'react-native-safe-area-context';

import { ConversationScreen } from '@/screens/ConversationScreen';
import { OnboardingScreen } from '@/screens/OnboardingScreen';
import { DisclaimerModal } from '@/components/DisclaimerModal';

type Stage = 'onboarding' | 'disclaimer' | 'conversation';

export default function App() {
  const [stage, setStage] = useState<Stage>('onboarding');

  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      <SafeAreaProvider>
        <StatusBar style="light" />
        {stage === 'onboarding' && (
          <OnboardingScreen onContinue={() => setStage('disclaimer')} />
        )}
        {stage === 'disclaimer' && (
          <>
            <ConversationScreen />
            <DisclaimerModal
              visible
              variant="onboarding"
              onAccept={() => setStage('conversation')}
            />
          </>
        )}
        {stage === 'conversation' && <ConversationScreen />}
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}
