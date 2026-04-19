import React, { useEffect } from 'react';
import { StyleSheet, View } from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import Animated, {
  Easing,
  useAnimatedStyle,
  useSharedValue,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';

import { gradients, palette } from '@/theme/colors';

const AnimatedGradient = Animated.createAnimatedComponent(LinearGradient);

/**
 * Slow-moving aurora wash. Two stacked gradients at different angles
 * drift through translation cycles measured in tens of seconds, so the
 * background reads as still on first glance and only reveals motion if
 * you sit with it for a moment. That's the point.
 */
export function AuroraBackground({ children }: { children?: React.ReactNode }) {
  const t1 = useSharedValue(0);
  const t2 = useSharedValue(0);

  useEffect(() => {
    t1.value = withRepeat(
      withTiming(1, { duration: 28000, easing: Easing.inOut(Easing.quad) }),
      -1,
      true
    );
    t2.value = withRepeat(
      withTiming(1, { duration: 36000, easing: Easing.inOut(Easing.sin) }),
      -1,
      true
    );
  }, [t1, t2]);

  const layer1 = useAnimatedStyle(() => ({
    transform: [
      { translateY: -40 + t1.value * 80 },
      { translateX: -20 + t1.value * 40 },
    ],
    opacity: 0.85,
  }));

  const layer2 = useAnimatedStyle(() => ({
    transform: [
      { translateY: 30 - t2.value * 60 },
      { translateX: 20 - t2.value * 40 },
    ],
    opacity: 0.55,
  }));

  return (
    <View style={styles.root}>
      <View style={styles.base} />
      <AnimatedGradient
        colors={gradients.aurora}
        start={{ x: 0, y: 0 }}
        end={{ x: 1, y: 1 }}
        style={[styles.layer, layer1]}
      />
      <AnimatedGradient
        colors={[palette.midnight, palette.dusk, 'transparent', palette.rose]}
        start={{ x: 1, y: 0 }}
        end={{ x: 0, y: 1 }}
        style={[styles.layer, layer2]}
      />
      <View style={styles.vignette} />
      <View style={styles.content}>{children}</View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: palette.midnight },
  base: { ...StyleSheet.absoluteFillObject, backgroundColor: palette.midnight },
  layer: { ...StyleSheet.absoluteFillObject },
  vignette: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(11, 15, 44, 0.18)',
  },
  content: { flex: 1 },
});
