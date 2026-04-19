import React, { useEffect } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import * as Haptics from 'expo-haptics';
import Animated, {
  useAnimatedStyle,
  useSharedValue,
  withSpring,
} from 'react-native-reanimated';

import { palette } from '@/theme/colors';
import { radius, spacing } from '@/theme/spacing';
import { type } from '@/theme/typography';

interface MicButtonProps {
  isActive: boolean;
  disabled?: boolean;
  label?: string;
  onPressIn: () => void;
  onPressOut: () => void;
}

/**
 * Hold-to-talk button.
 *
 * The label hugs the button (not floats above it) so press targets stay
 * obvious. We use haptics on engagement so the user has a confirmed,
 * physical "I'm in" moment before they speak — which matters because
 * the model is listening for the beginning of their breath.
 */
export function MicButton({
  isActive,
  disabled,
  label = 'Hold to speak',
  onPressIn,
  onPressOut,
}: MicButtonProps) {
  const scale = useSharedValue(1);

  useEffect(() => {
    scale.value = withSpring(isActive ? 0.94 : 1, { damping: 12, stiffness: 180 });
  }, [isActive, scale]);

  const animStyle = useAnimatedStyle(() => ({
    transform: [{ scale: scale.value }],
  }));

  return (
    <View style={styles.wrap}>
      <Animated.View style={animStyle}>
        <Pressable
          accessibilityRole="button"
          accessibilityLabel="Hold to speak"
          accessibilityState={{ disabled, busy: isActive }}
          onPressIn={() => {
            if (disabled) return;
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => undefined);
            onPressIn();
          }}
          onPressOut={() => {
            if (disabled) return;
            Haptics.selectionAsync().catch(() => undefined);
            onPressOut();
          }}
          style={({ pressed }) => [
            styles.btn,
            isActive && styles.btnActive,
            disabled && styles.btnDisabled,
            pressed && !disabled && styles.btnPressed,
          ]}
        >
          <View style={[styles.dot, isActive && styles.dotActive]} />
        </Pressable>
      </Animated.View>
      <Text style={styles.label}>
        {disabled ? 'Preparing…' : isActive ? 'Listening — release to send' : label}
      </Text>
    </View>
  );
}

const styles = StyleSheet.create({
  wrap: { alignItems: 'center', gap: spacing.md },
  btn: {
    width: 96,
    height: 96,
    borderRadius: radius.pill,
    backgroundColor: palette.glass,
    borderWidth: 1.5,
    borderColor: palette.glassBorder,
    alignItems: 'center',
    justifyContent: 'center',
  },
  btnActive: {
    backgroundColor: 'rgba(217, 162, 184, 0.22)',
    borderColor: palette.rose,
  },
  btnPressed: { opacity: 0.85 },
  btnDisabled: { opacity: 0.45 },
  dot: {
    width: 28,
    height: 28,
    borderRadius: 14,
    backgroundColor: palette.paperFaint,
  },
  dotActive: { backgroundColor: palette.peach },
  label: {
    ...type.caption,
    color: palette.paperSoft,
  },
});
