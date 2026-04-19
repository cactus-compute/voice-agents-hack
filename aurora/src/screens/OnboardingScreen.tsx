import React from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

import { AuroraBackground } from '@/components/AuroraBackground';
import { BreathingOrb } from '@/components/BreathingOrb';
import { palette } from '@/theme/colors';
import { radius, spacing } from '@/theme/spacing';
import { type } from '@/theme/typography';

interface OnboardingScreenProps {
  onContinue: () => void;
}

export function OnboardingScreen({ onContinue }: OnboardingScreenProps) {
  return (
    <AuroraBackground>
      <SafeAreaView style={styles.safe} edges={['top', 'bottom']}>
        <View style={styles.hero}>
          <BreathingOrb phase="idle" size={200} />
        </View>
        <View style={styles.copy}>
          <Text style={styles.eyebrow}>Aurora</Text>
          <Text style={styles.title}>A quiet place{'\n'}to think out loud.</Text>
          <Text style={styles.body}>
            Hold the circle and speak. Aurora listens, reflects, and responds —
            entirely on this device. Nothing you say leaves your phone.
          </Text>
        </View>
        <Pressable
          accessibilityRole="button"
          onPress={onContinue}
          style={({ pressed }) => [styles.cta, pressed && { opacity: 0.85 }]}
        >
          <Text style={styles.ctaLabel}>Begin</Text>
        </Pressable>
      </SafeAreaView>
    </AuroraBackground>
  );
}

const styles = StyleSheet.create({
  safe: { flex: 1, paddingHorizontal: spacing.lg },
  hero: {
    flex: 1.2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  copy: {
    flex: 1,
    gap: spacing.md,
    paddingHorizontal: spacing.sm,
  },
  eyebrow: { ...type.caption, color: palette.paperFaint },
  title: { ...type.hero, color: palette.paper },
  body: { ...type.body, color: palette.paperSoft },
  cta: {
    marginBottom: spacing.lg,
    paddingVertical: spacing.md,
    borderRadius: radius.pill,
    backgroundColor: palette.paper,
    alignItems: 'center',
  },
  ctaLabel: {
    ...type.body,
    color: palette.ink,
    fontWeight: '600',
    letterSpacing: 0.4,
  },
});
