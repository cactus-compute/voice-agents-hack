import React from 'react';
import {
  Modal,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';

import { gradients, palette } from '@/theme/colors';
import { radius, spacing } from '@/theme/spacing';
import { type } from '@/theme/typography';
import { CRISIS_RESOURCES, DISCLAIMER } from '@/constants/safety';

interface DisclaimerModalProps {
  visible: boolean;
  onAccept: () => void;
  /** When true, the modal renders the urgent crisis variant instead of onboarding. */
  variant?: 'onboarding' | 'crisis';
  onDismissCrisis?: () => void;
}

export function DisclaimerModal({
  visible,
  onAccept,
  variant = 'onboarding',
  onDismissCrisis,
}: DisclaimerModalProps) {
  const isCrisis = variant === 'crisis';
  return (
    <Modal
      visible={visible}
      transparent
      animationType="fade"
      onRequestClose={isCrisis ? onDismissCrisis : undefined}
    >
      <View style={styles.scrim}>
        <LinearGradient
          colors={isCrisis
            ? ['#3A1F22', '#2E2C5A']
            : [palette.midnight, palette.dusk]}
          style={styles.sheet}
        >
          <ScrollView
            contentContainerStyle={styles.content}
            showsVerticalScrollIndicator={false}
          >
            <Text style={styles.eyebrow}>
              {isCrisis ? 'A pause' : 'Before we begin'}
            </Text>
            <Text style={styles.title}>
              {isCrisis
                ? 'Please reach out to a human right now.'
                : 'Aurora is a quiet place to think out loud.'}
            </Text>

            {isCrisis ? (
              <>
                <Text style={styles.body}>
                  Aurora isn't equipped for what you're carrying alone. A real
                  person on the other end of a phone can be with you in a way
                  this app can't.
                </Text>
                <View style={styles.resourceBlock}>
                  <Text style={styles.resourceLabel}>{CRISIS_RESOURCES.us.label}</Text>
                  <Text style={styles.resourceMeta}>Call or text 988 — 24/7, free, confidential.</Text>
                </View>
                <View style={styles.resourceBlock}>
                  <Text style={styles.resourceLabel}>{CRISIS_RESOURCES.intl.label}</Text>
                  <Text style={styles.resourceMeta}>findahelpline.com lists hotlines for 130+ countries.</Text>
                </View>
              </>
            ) : (
              <Text style={styles.body}>{DISCLAIMER}</Text>
            )}

            <Pressable
              accessibilityRole="button"
              onPress={isCrisis ? onDismissCrisis : onAccept}
              style={({ pressed }) => [
                styles.cta,
                pressed && { opacity: 0.85 },
                isCrisis && styles.ctaCrisis,
              ]}
            >
              <Text style={styles.ctaLabel}>
                {isCrisis ? 'Okay, I see this' : 'I understand — let’s begin'}
              </Text>
            </Pressable>
          </ScrollView>
        </LinearGradient>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  scrim: {
    flex: 1,
    backgroundColor: 'rgba(0, 0, 0, 0.5)',
    justifyContent: 'flex-end',
  },
  sheet: {
    borderTopLeftRadius: radius.xl,
    borderTopRightRadius: radius.xl,
    paddingHorizontal: spacing.lg,
    paddingTop: spacing.xl,
    paddingBottom: spacing.xxl,
    maxHeight: '88%',
  },
  content: { gap: spacing.md },
  eyebrow: { ...type.caption, color: palette.paperFaint },
  title: { ...type.title, color: palette.paper },
  body: { ...type.body, color: palette.paperSoft },
  resourceBlock: {
    paddingVertical: spacing.md,
    paddingHorizontal: spacing.md,
    borderRadius: radius.md,
    backgroundColor: palette.glass,
    borderWidth: 1,
    borderColor: palette.glassBorder,
    gap: spacing.xs,
  },
  resourceLabel: { ...type.body, color: palette.paper, fontWeight: '600' },
  resourceMeta: { ...type.meta, color: palette.paperSoft },
  cta: {
    marginTop: spacing.lg,
    paddingVertical: spacing.md,
    borderRadius: radius.pill,
    backgroundColor: palette.paper,
    alignItems: 'center',
  },
  ctaCrisis: { backgroundColor: palette.peach },
  ctaLabel: {
    ...type.body,
    color: palette.ink,
    fontWeight: '600',
    letterSpacing: 0.3,
  },
});
